// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {SpreadCurve} from "./SpreadCurve.sol";
import {Vault} from "./Vault.sol";
import {OracleAdapter} from "./OracleAdapter.sol";
import {GBPF} from "./GBPF.sol";
import {IPSM3} from "./interfaces/IPSM3.sol";

/// @title GBPF V4 hook
/// @notice The protocol. Intercepts swaps against the configured (USDS, GBPF) pool and
///         executes them as primary-market mint/redeem against the vault, priced by
///         oracle TWAP + solvency-indexed curve + flat fee.
///
///         See HOOK_DESIGN.md for the full design rationale.
///
///         Immutable. No owner, no admin, no upgrade path.
contract Hook is IHooks {
    using SafeTransferLib for address;

    // ============================================================================================
    // Immutable configuration
    // ============================================================================================

    IPoolManager public immutable POOL_MANAGER;
    Vault public immutable VAULT;
    OracleAdapter public immutable ORACLE;
    GBPF public immutable GBPF_TOKEN;
    address public immutable USDS;
    address public immutable SUSDS;
    IPSM3 public immutable PSM3;

    /// @dev True iff address(USDS) < address(GBPF). Determined at deploy. Drives the
    ///      zeroForOne ↔ mint/redeem mapping.
    bool public immutable USDS_IS_TOKEN0;

    /// @dev The exact PoolKey hash this hook services. Stored as a hash (32 bytes) rather
    ///      than reconstructing the full struct on every call.
    bytes32 public immutable POOL_KEY_HASH;

    // ============================================================================================
    // Constants
    // ============================================================================================

    uint256 internal constant WAD = 1e18;
    int256 internal constant WAD_INT = 1e18;

    /// @dev Flat protocol fee, in WAD. 20 bp = 0.002 = 2e15.
    uint256 internal constant FLAT_FEE_WAD = 2e15;

    /// @dev ray = 1e27, used by SSRAuthOracle for USDS/sUSDS conversion.
    uint256 internal constant RAY = 1e27;

    // ============================================================================================
    // Events
    // ============================================================================================

    event Mint(address indexed user, uint256 usdsIn, uint256 gbpfOut, uint256 feeUsds);
    event Redeem(address indexed user, uint256 gbpfIn, uint256 usdsOut, uint256 feeUsds);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error NotPoolManager();
    error WrongPool();
    error OraclePaused();
    error ZeroSwap();
    error InvalidHookCall();

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(
        address poolManager_,
        address vault_,
        address oracleAdapter_,
        address gbpf_,
        address usds_,
        address sUsds_,
        address psm3_
    ) {
        POOL_MANAGER = IPoolManager(poolManager_);
        VAULT = Vault(vault_);
        ORACLE = OracleAdapter(oracleAdapter_);
        GBPF_TOKEN = GBPF(gbpf_);
        USDS = usds_;
        SUSDS = sUsds_;
        PSM3 = IPSM3(psm3_);

        USDS_IS_TOKEN0 = usds_ < gbpf_;

        // Pre-compute and store the PoolKey hash. The pool uses fee=0, tickSpacing=1, and
        // this contract as the hooks address. Currencies are sorted by address (V4 convention).
        Currency c0 = USDS_IS_TOKEN0 ? Currency.wrap(usds_) : Currency.wrap(gbpf_);
        Currency c1 = USDS_IS_TOKEN0 ? Currency.wrap(gbpf_) : Currency.wrap(usds_);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        POOL_KEY_HASH = keccak256(abi.encode(key));

        // One-time max approvals: PSM3 will pull USDS and sUSDS from this contract on every
        // swap. Setting max once at deploy avoids per-swap approval gas.
        usds_.safeApprove(psm3_, type(uint256).max);
        sUsds_.safeApprove(psm3_, type(uint256).max);
    }

    // ============================================================================================
    // IHooks callbacks
    //
    // Only beforeSwap is functional. The other callbacks revert InvalidHookCall as defence in
    // depth — they will never be called in normal operation because the corresponding flag bits
    // are not set in the hook's CREATE2-mined address, and V4's PoolManager only invokes a
    // callback if the matching bit is set.
    // ============================================================================================

    /// @notice V4 hook callback invoked before every swap against the (USDS, GBPF) pool.
    ///         Fully replaces V4's pool math with an oracle-priced mint/redeem against the vault.
    /// @dev    Verifies the caller is the PoolManager, the PoolKey matches the one bound at
    ///         deploy, the amountSpecified is non-zero, and the oracle is healthy. Then computes
    ///         solvency, gets the spread from SpreadCurve, dispatches to either _handleMint or
    ///         _handleRedeem depending on `params.zeroForOne` and the USDS_IS_TOKEN0 immutable.
    ///
    ///         Both mint (USDS → GBPF) and redeem (GBPF → USDS) flows support exact-input
    ///         (amountSpecified < 0) and exact-output (amountSpecified > 0). Exact-output
    ///         inverts the linear price multiplier analytically; the curve itself is evaluated
    ///         only once per swap from the pre-swap solvency.
    ///
    ///         All token movements are within this single call frame: tokens are pulled from
    ///         the PoolManager via `take`, swapped via Spark PSM3, deposited to or withdrawn
    ///         from the Vault, GBPF is minted to / burned from this contract, and the final
    ///         payment back to the PoolManager is settled via `sync` + `transfer` + `settle`.
    ///
    /// @param  key            The PoolKey of the pool being swapped on. Must match the
    ///                        committed POOL_KEY_HASH or the call reverts WrongPool.
    /// @param  params         The swap parameters as supplied by the swapper.
    /// @return selector       IHooks.beforeSwap.selector — required by V4 for callback validation.
    /// @return delta          BeforeSwapDelta packed as (specifiedDelta, unspecifiedDelta).
    ///                        The deltas tell the PoolManager that the hook has fully handled
    ///                        the trade and the pool's own math should not run.
    /// @return overrideFee    Always 0 — we do not use V4's dynamic LP fee mechanism.
    ///
    /// Reverts with:
    /// - `NotPoolManager`    if msg.sender is not the configured PoolManager.
    /// - `WrongPool`         if the PoolKey hash does not match POOL_KEY_HASH.
    /// - `ZeroSwap`          if amountSpecified is zero, or if the computed input/output is
    ///                        zero (e.g. dust amounts that round to zero through pricing).
    /// - `OraclePaused`      if the OracleAdapter reports unhealthy (any pause trigger active).
    /// - `InvalidHookCall`   if GBPF total supply is zero (an off-bootstrap invariant violation;
    ///                        the protocol is bootstrapped to non-zero supply at deploy).
    /// - `AmountTooLarge`    if a token amount exceeds int128 max (~1.7e38; far above any
    ///                        realistic swap size).
    function beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /* hookData */
    )
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (keccak256(abi.encode(key)) != POOL_KEY_HASH) revert WrongPool();
        if (params.amountSpecified == 0) revert ZeroSwap();

        // 1. Check oracle health and pull TWAP.
        (uint256 twapWad, bool healthy,) = ORACLE.update();
        if (!healthy) revert OraclePaused();

        // 2. Settle vault yield and read solvency inputs.
        (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrRate, uint256 usdsClaimBacking) =
            VAULT.solvencyInputs();

        // 3. Compute solvency. principal sUSDS × ray rate / twap / supply + USDS claim backing / twap,
        //    all in WAD. GBPF supply at deploy is bootstrapped to non-zero ($1 seed).
        uint256 gbpfSupply = GBPF_TOKEN.totalSupply();
        if (gbpfSupply == 0) revert InvalidHookCall();
        uint256 solvencyWad =
            _computeSolvencyWad(sUsdsBalance, pendingBeneficiary, ssrRate, usdsClaimBacking, twapWad, gbpfSupply);

        // 4. Get the spread.
        int256 spreadWad = SpreadCurve.spread(solvencyWad);

        // 5. Dispatch by direction.
        bool isMint = (params.zeroForOne == USDS_IS_TOKEN0);
        bool isExactInput = (params.amountSpecified < 0);

        if (isMint) {
            return _handleMint(params, twapWad, spreadWad, isExactInput);
        } else {
            return _handleRedeem(params, twapWad, spreadWad, isExactInput);
        }
    }

    /// @notice Unused; reverts as defence in depth. PoolManager will not call this because the
    ///         BEFORE_INITIALIZE_FLAG bit is not set in this hook's address.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. See {beforeInitialize}.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. The protocol does not support adding LP
    ///         positions to this pool — there are no LPs by design.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. See {beforeAddLiquidity}.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. See {beforeAddLiquidity}.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. See {beforeAddLiquidity}.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. All swap logic happens in {beforeSwap}.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. The pool does not support donations.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    /// @notice Unused; reverts as defence in depth. See {beforeDonate}.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    // ============================================================================================
    // Pricing
    // ============================================================================================

    /// @dev Compute the solvency ratio in WAD. Backing comes from two sources:
    ///        (a) sUSDS principal in the vault, converted to USDS-value via the SSR rate;
    ///        (b) USDS-denominated 6909 claims the Vault holds on the PoolManager, awaiting
    ///            flush. These are real USDS obligations on PM and count at 1:1 USDS-value.
    ///      Combined USDS-value is divided by twap to get GBP-value, then by GBPF supply.
    ///
    /// @param sUsdsBalance       Vault sUSDS balance, in 18-decimal sUSDS shares.
    /// @param pendingBeneficiary sUSDS owed to the beneficiary, in 18-decimal shares.
    /// @param ssrRate            Spark SSRAuthOracle conversion rate, in ray (1e27).
    /// @param usdsClaimBacking   USDS-denominated 6909 claims backing GBPF (already net of beneficiary).
    /// @param twapWad            GBP/USD TWAP, in WAD (1e18).
    /// @param gbpfSupply         GBPF.totalSupply(), in 18-decimal GBPF.
    /// @return solvencyWad       Solvency in WAD. 1e18 == 100% solvency.
    function _computeSolvencyWad(
        uint256 sUsdsBalance,
        uint256 pendingBeneficiary,
        uint256 ssrRate,
        uint256 usdsClaimBacking,
        uint256 twapWad,
        uint256 gbpfSupply
    ) internal pure returns (uint256) {
        uint256 principal = sUsdsBalance > pendingBeneficiary ? sUsdsBalance - pendingBeneficiary : 0;
        uint256 sUsdsUsdsValue = FixedPointMathLib.mulDiv(principal, ssrRate, RAY);
        uint256 totalUsdsValue = sUsdsUsdsValue + usdsClaimBacking;
        uint256 collateralGbpWad = FixedPointMathLib.mulDiv(totalUsdsValue, WAD, twapWad);
        return FixedPointMathLib.mulDiv(collateralGbpWad, WAD, gbpfSupply);
    }

    /// @dev Returns the mint price (USDS per GBPF) in WAD: twap * (WAD + spread + flatFee).
    function _mintPriceWad(uint256 twapWad, int256 spreadWad) internal pure returns (uint256) {
        // Safety: FLAT_FEE_WAD = 2e15 ≪ 2^255; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 mul = WAD_INT + spreadWad + int256(FLAT_FEE_WAD);
        // mul is positive in any operating regime; bounded below by:
        //   spreadWad ≥ -S_MAX = -5e16, so WAD - 5e16 + 2e15 ≈ 9.5e17 > 0.
        require(mul > 0, "mul nonpositive");
        // Safety: mul > 0 by the check above; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        return FixedPointMathLib.mulWad(twapWad, uint256(mul));
    }

    /// @dev Returns the redeem price (USDS per GBPF) in WAD: twap * (WAD + spread - flatFee).
    function _redeemPriceWad(uint256 twapWad, int256 spreadWad) internal pure returns (uint256) {
        // Safety: FLAT_FEE_WAD = 2e15 ≪ 2^255; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 mul = WAD_INT + spreadWad - int256(FLAT_FEE_WAD);
        require(mul > 0, "mul nonpositive");
        // Safety: mul > 0 by the check above; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        return FixedPointMathLib.mulWad(twapWad, uint256(mul));
    }

    // ============================================================================================
    // Mint flow
    // ============================================================================================

    /// @dev Execute a mint swap (USDS → GBPF). Pull USDS from PoolManager, convert to sUSDS via
    ///      Spark PSM3 (delivered straight to the vault), record the deposit with the protocol
    ///      fee separated out, mint GBPF to this contract, push GBPF to PoolManager via
    ///      sync/transfer/settle, and return the BeforeSwapDelta describing the trade.
    ///
    /// @param params      The original swap params from V4. Used for amountSpecified.
    /// @param twapWad     GBP/USD TWAP read from the OracleAdapter, in WAD.
    /// @param spreadWad   Signed spread from SpreadCurve evaluated at pre-swap solvency.
    /// @param isExactInput true if amountSpecified < 0 (user supplies USDS amount),
    ///                     false if amountSpecified > 0 (user requests GBPF amount).
    function _handleMint(SwapParams calldata params, uint256 twapWad, int256 spreadWad, bool isExactInput)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 mintPriceWad = _mintPriceWad(twapWad, spreadWad);
        uint256 usdsIn;
        uint256 gbpfOut;

        if (isExactInput) {
            usdsIn = uint256(-params.amountSpecified);
            gbpfOut = FixedPointMathLib.mulDiv(usdsIn, WAD, mintPriceWad);
        } else {
            gbpfOut = uint256(params.amountSpecified);
            usdsIn = FixedPointMathLib.mulDivUp(gbpfOut, mintPriceWad, WAD);
        }
        if (usdsIn == 0 || gbpfOut == 0) revert ZeroSwap();

        // Fee in USDS terms (proportional): feeUsds = usdsIn * flatFee * twap / mintPriceWad.
        uint256 feeUsds = FixedPointMathLib.mulDiv(usdsIn, FLAT_FEE_WAD * twapWad / WAD, mintPriceWad);
        if (feeUsds > usdsIn) feeUsds = usdsIn;

        // Token plumbing.
        // 1. PM.mint(VAULT, USDS_id, usdsIn): credit the Vault a 6909 USDS claim, debit the hook
        //    by usdsIn USDS delta. The router's post-swap settle from user → PM will pay this debt.
        // 2. Vault records the claim + fee.
        // 3. Mint GBPF to self, sync + transfer + settle to PM (so PM owes user the GBPF).
        uint256 usdsId = uint256(uint160(USDS));
        POOL_MANAGER.mint(address(VAULT), usdsId, usdsIn);
        VAULT.recordMint(usdsIn, feeUsds);

        Currency gbpfC = Currency.wrap(address(GBPF_TOKEN));
        GBPF_TOKEN.mint(address(this), gbpfOut);
        POOL_MANAGER.sync(gbpfC);
        address(GBPF_TOKEN).safeTransfer(address(POOL_MANAGER), gbpfOut);
        POOL_MANAGER.settle();

        emit Mint(tx.origin, usdsIn, gbpfOut, feeUsds);

        // Build the BeforeSwapDelta.
        // specified delta: positive of usdsIn (we, the hook, are taking the user's specified token)
        //                  for exactInput where amountSpecified<0, we want specified=+usdsIn so
        //                  PM credits the hook for what the user paid. For exactOutput where
        //                  amountSpecified>0 we want specified=-gbpfOut so PM debits the hook by
        //                  what it owes the user.
        // unspecified delta: the opposite side.
        int128 specifiedDelta;
        int128 unspecifiedDelta;
        if (isExactInput) {
            // specified token is USDS (the input). Hook is owed usdsIn.
            // unspecified token is GBPF (the output). Hook owes gbpfOut.
            specifiedDelta = _toPositiveInt128(usdsIn);
            unspecifiedDelta = -_toPositiveInt128(gbpfOut);
        } else {
            // specified token is GBPF (the output). Hook owes gbpfOut.
            // unspecified token is USDS (the input). Hook is owed usdsIn.
            specifiedDelta = -_toPositiveInt128(gbpfOut);
            unspecifiedDelta = _toPositiveInt128(usdsIn);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ============================================================================================
    // Redeem flow
    // ============================================================================================

    /// @dev Execute a redeem swap (GBPF → USDS). Pull GBPF from PoolManager, burn it,
    ///      withdraw sUSDS from the vault (separating fee from principal), convert to USDS
    ///      via Spark PSM3 using exactOut so the user receives exactly `usdsOut` USDS, push
    ///      that USDS to PoolManager via sync/transfer/settle, and return the BeforeSwapDelta.
    ///
    /// @param params      The original swap params from V4.
    /// @param twapWad     GBP/USD TWAP from the OracleAdapter, in WAD.
    /// @param spreadWad   Signed spread from SpreadCurve evaluated at pre-swap solvency.
    /// @param isExactInput true if amountSpecified < 0 (user supplies GBPF amount),
    ///                     false if amountSpecified > 0 (user requests USDS amount).
    function _handleRedeem(SwapParams calldata params, uint256 twapWad, int256 spreadWad, bool isExactInput)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 redeemPriceWad = _redeemPriceWad(twapWad, spreadWad);
        uint256 gbpfIn;
        uint256 usdsOut;

        if (isExactInput) {
            gbpfIn = uint256(-params.amountSpecified);
            usdsOut = FixedPointMathLib.mulDiv(gbpfIn, redeemPriceWad, WAD);
        } else {
            usdsOut = uint256(params.amountSpecified);
            gbpfIn = FixedPointMathLib.mulDivUp(usdsOut, WAD, redeemPriceWad);
        }
        if (gbpfIn == 0 || usdsOut == 0) revert ZeroSwap();

        // Fee in USDS terms: feeUsds = usdsOut * flatFee * twap / redeemPriceWad.
        uint256 feeUsds = FixedPointMathLib.mulDiv(usdsOut, FLAT_FEE_WAD * twapWad / WAD, redeemPriceWad);

        // 1. PM.mint(VAULT, GBPF_id, gbpfIn): credit Vault a 6909 GBPF claim, debit hook
        //    gbpfIn GBPF. Router's post-swap settle from user → PM will pay this debt.
        // 2. Vault.recordRedeem moves sUSDS from vault to hook (for PSM3 conversion) and
        //    records the GBPF claim + sUSDS-fee credit.
        // 3. Convert sUSDS → USDS via PSM3.swapExactOut, sending output to hook.
        // 4. Hook syncs + transfers + settles USDS to PM (credits PM with USDS owed to user).
        uint256 gbpfId = uint256(uint160(address(GBPF_TOKEN)));
        POOL_MANAGER.mint(address(VAULT), gbpfId, gbpfIn);

        // Ask PSM3 how much sUSDS we need to deliver `usdsOut` USDS.
        uint256 sUsdsForUser = PSM3.previewSwapExactOut(SUSDS, USDS, usdsOut);
        uint256 feeSUsds = FixedPointMathLib.mulDiv(sUsdsForUser, feeUsds, usdsOut);

        // Vault transfers sUsdsForUser to this hook + records the GBPF claim and beneficiary fee.
        VAULT.recordRedeem(sUsdsForUser, gbpfIn, feeSUsds);

        // Convert sUSDS → USDS via PSM3.
        PSM3.swapExactOut(SUSDS, USDS, usdsOut, sUsdsForUser, address(this), 0);

        // Push USDS to PoolManager so PM can pay the user during router settle.
        Currency usdsC = Currency.wrap(USDS);
        POOL_MANAGER.sync(usdsC);
        USDS.safeTransfer(address(POOL_MANAGER), usdsOut);
        POOL_MANAGER.settle();

        emit Redeem(tx.origin, gbpfIn, usdsOut, feeUsds);

        int128 specifiedDelta;
        int128 unspecifiedDelta;
        if (isExactInput) {
            specifiedDelta = _toPositiveInt128(gbpfIn);
            unspecifiedDelta = -_toPositiveInt128(usdsOut);
        } else {
            specifiedDelta = -_toPositiveInt128(usdsOut);
            unspecifiedDelta = _toPositiveInt128(gbpfIn);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ============================================================================================
    // Cast helpers
    // ============================================================================================

    /// @dev Cast a non-negative uint256 amount to int128 for use in BeforeSwapDelta packing.
    ///      Reverts AmountTooLarge if the value exceeds int128 max.
    ///
    ///      The amounts cast here are mint/redeem token quantities. Realistic operating
    ///      bounds (sUSDS / USDS / GBPF amounts in 18-decimal WAD units) are far below
    ///      int128 max (~1.7e38), but for an immutable on-chain contract we revert visibly
    ///      rather than silently wrap.
    function _toPositiveInt128(uint256 amount) internal pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge(amount);
        // Safety: amount ≤ int128 max by the check above; both casts are sound.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(int256(amount));
    }

    error AmountTooLarge(uint256 amount);
}
