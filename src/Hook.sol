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
    // IHooks: only beforeSwap is implemented. The other hook callbacks revert because the
    // corresponding flags are not set on our address, so V4's PoolManager will never invoke them.
    // ============================================================================================

    function beforeSwap(
        address,
        /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
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
        (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrRate) = VAULT.solvencyInputs();

        // 3. Compute solvency. principal sUSDS × ray rate / twap / supply, all in WAD.
        //    GBPF supply at deploy is bootstrapped to non-zero ($1 seed), so totalSupply > 0
        //    is an invariant; we still defensively guard.
        uint256 gbpfSupply = GBPF_TOKEN.totalSupply();
        if (gbpfSupply == 0) revert InvalidHookCall();
        uint256 solvencyWad = _computeSolvencyWad(sUsdsBalance, pendingBeneficiary, ssrRate, twapWad, gbpfSupply);

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

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidHookCall();
    }

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

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidHookCall();
    }

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

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert InvalidHookCall();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert InvalidHookCall();
    }

    // ============================================================================================
    // Pricing
    // ============================================================================================

    /// @dev s = (sUsdsBalance - pendingBeneficiary) * ssrRate / RAY / twapWad / gbpfSupply, in WAD.
    function _computeSolvencyWad(
        uint256 sUsdsBalance,
        uint256 pendingBeneficiary,
        uint256 ssrRate,
        uint256 twapWad,
        uint256 gbpfSupply
    ) internal pure returns (uint256) {
        uint256 principal = sUsdsBalance > pendingBeneficiary ? sUsdsBalance - pendingBeneficiary : 0;
        // collateralUsdsWad = principal (in sUSDS shares, 18 decimals) * ssrRate / RAY
        // = USDS-value of the principal in WAD.
        uint256 collateralUsdsWad = FixedPointMathLib.mulDiv(principal, ssrRate, RAY);
        // collateralGbpWad = collateralUsdsWad / twap (USDS-per-GBP)
        uint256 collateralGbpWad = FixedPointMathLib.mulDiv(collateralUsdsWad, WAD, twapWad);
        // s = collateralGbpWad / gbpfSupply
        return FixedPointMathLib.mulDiv(collateralGbpWad, WAD, gbpfSupply);
    }

    /// @dev Returns the mint price (USDS per GBPF) in WAD: twap * (WAD + spread + flatFee).
    function _mintPriceWad(uint256 twapWad, int256 spreadWad) internal pure returns (uint256) {
        int256 mul = WAD_INT + spreadWad + int256(FLAT_FEE_WAD);
        // mul is positive in any operating regime; bounded below by:
        //   spreadWad ≥ -S_MAX = -5e16, so WAD - 5e16 + 2e15 ≈ 9.5e17 > 0.
        require(mul > 0, "mul nonpositive");
        return FixedPointMathLib.mulWad(twapWad, uint256(mul));
    }

    /// @dev Returns the redeem price (USDS per GBPF) in WAD: twap * (WAD + spread - flatFee).
    function _redeemPriceWad(uint256 twapWad, int256 spreadWad) internal pure returns (uint256) {
        int256 mul = WAD_INT + spreadWad - int256(FLAT_FEE_WAD);
        require(mul > 0, "mul nonpositive");
        return FixedPointMathLib.mulWad(twapWad, uint256(mul));
    }

    // ============================================================================================
    // Mint flow
    // ============================================================================================

    function _handleMint(SwapParams calldata params, uint256 twapWad, int256 spreadWad, bool isExactInput)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 mintPriceWad = _mintPriceWad(twapWad, spreadWad);
        uint256 usdsIn;
        uint256 gbpfOut;

        if (isExactInput) {
            usdsIn = uint256(-params.amountSpecified);
            // gbpfOut = usdsIn * WAD / mintPriceUsdsPerGbpf  (round down — protocol-safe)
            gbpfOut = FixedPointMathLib.mulDiv(usdsIn, WAD, mintPriceWad);
        } else {
            gbpfOut = uint256(params.amountSpecified);
            // usdsIn = ceilDiv(gbpfOut * mintPriceWad, WAD) — round up so the user pays enough.
            usdsIn = FixedPointMathLib.mulDivUp(gbpfOut, mintPriceWad, WAD);
        }
        if (usdsIn == 0 || gbpfOut == 0) revert ZeroSwap();

        // Fee in USDS terms (proportional): feeUsds = usdsIn * flatFee / mintMultiplier.
        // Equivalent simpler form: feeUsds = usdsIn * flatFee / (WAD + spread + flatFee)
        // = usdsIn * flatFee * WAD / (mintPriceWad * WAD / twapWad)
        // We compute it directly to avoid recomputing the multiplier:
        // feeUsds = usdsIn * flatFee / mintMultiplier, where mintMultiplier = mintPriceWad / twapWad.
        // i.e. feeUsds = usdsIn * flatFee * twap / mintPriceWad.
        uint256 feeUsds = FixedPointMathLib.mulDiv(usdsIn, FLAT_FEE_WAD * twapWad / WAD, mintPriceWad);
        // Defensive clamp: feeUsds must not exceed usdsIn (it's a portion of it).
        if (feeUsds > usdsIn) feeUsds = usdsIn;

        // Token plumbing.
        Currency usdsC = Currency.wrap(USDS);
        Currency gbpfC = Currency.wrap(address(GBPF_TOKEN));

        // Pull USDS from PoolManager.
        POOL_MANAGER.take(usdsC, address(this), usdsIn);

        // Convert USDS → sUSDS via PSM3. Preview first so we can use the exact amount as
        // minAmountOut — PSM and we use the same SSRAuthOracle, so preview agrees exactly.
        uint256 sUsdsExpected = PSM3.previewSwapExactIn(USDS, SUSDS, usdsIn);
        uint256 sUsdsReceived = PSM3.swapExactIn(USDS, SUSDS, usdsIn, sUsdsExpected, address(VAULT), 0);

        // Compute the sUSDS-denominated fee proportional to the USDS-denominated fee.
        uint256 feeSUsds = FixedPointMathLib.mulDiv(sUsdsReceived, feeUsds, usdsIn);

        // Record the deposit and the fee credit.
        VAULT.deposit(sUsdsReceived, feeSUsds);

        // Mint GBPF to ourselves, then push to PoolManager via sync/transfer/settle.
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
            specifiedDelta = int128(int256(usdsIn));
            unspecifiedDelta = -int128(int256(gbpfOut));
        } else {
            // specified token is GBPF (the output). Hook owes gbpfOut.
            // unspecified token is USDS (the input). Hook is owed usdsIn.
            specifiedDelta = -int128(int256(gbpfOut));
            unspecifiedDelta = int128(int256(usdsIn));
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ============================================================================================
    // Redeem flow
    // ============================================================================================

    function _handleRedeem(SwapParams calldata params, uint256 twapWad, int256 spreadWad, bool isExactInput)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 redeemPriceWad = _redeemPriceWad(twapWad, spreadWad);
        uint256 gbpfIn;
        uint256 usdsOut;

        if (isExactInput) {
            gbpfIn = uint256(-params.amountSpecified);
            // usdsOut = gbpfIn * redeemPriceWad / WAD (round down)
            usdsOut = FixedPointMathLib.mulDiv(gbpfIn, redeemPriceWad, WAD);
        } else {
            usdsOut = uint256(params.amountSpecified);
            // gbpfIn = ceilDiv(usdsOut * WAD, redeemPriceWad) — round up so the user burns enough.
            gbpfIn = FixedPointMathLib.mulDivUp(usdsOut, WAD, redeemPriceWad);
        }
        if (gbpfIn == 0 || usdsOut == 0) revert ZeroSwap();

        // Fee in USDS terms: feeUsds = usdsOut * flatFee / redeemMultiplier
        // = usdsOut * flatFee * twap / redeemPriceWad
        // (the fee is the portion of the user's "should have got more" that we kept).
        uint256 feeUsds = FixedPointMathLib.mulDiv(usdsOut, FLAT_FEE_WAD * twapWad / WAD, redeemPriceWad);

        Currency usdsC = Currency.wrap(USDS);
        Currency gbpfC = Currency.wrap(address(GBPF_TOKEN));

        // Pull GBPF from PoolManager and burn it.
        POOL_MANAGER.take(gbpfC, address(this), gbpfIn);
        GBPF_TOKEN.burn(gbpfIn);

        // Ask the PSM how much sUSDS we need to deliver `usdsOut` USDS. Same oracle = exact agreement.
        uint256 sUsdsForUser = PSM3.previewSwapExactOut(SUSDS, USDS, usdsOut);

        // Compute the sUSDS-denominated fee proportional to the USDS-denominated fee.
        uint256 feeSUsds = FixedPointMathLib.mulDiv(sUsdsForUser, feeUsds, usdsOut);

        // Pull sUSDS from the vault: `sUsdsForUser` to us for the conversion, `feeSUsds` stays in
        // the vault credited to pendingBeneficiarySUsds.
        VAULT.withdraw(sUsdsForUser, address(this), feeSUsds);

        // Convert sUSDS → USDS via PSM3, sending the output to us so we can settle to PM.
        PSM3.swapExactOut(SUSDS, USDS, usdsOut, sUsdsForUser, address(this), 0);

        // Push USDS to PoolManager.
        POOL_MANAGER.sync(usdsC);
        USDS.safeTransfer(address(POOL_MANAGER), usdsOut);
        POOL_MANAGER.settle();

        emit Redeem(tx.origin, gbpfIn, usdsOut, feeUsds);

        int128 specifiedDelta;
        int128 unspecifiedDelta;
        if (isExactInput) {
            specifiedDelta = int128(int256(gbpfIn));
            unspecifiedDelta = -int128(int256(usdsOut));
        } else {
            specifiedDelta = -int128(int256(usdsOut));
            unspecifiedDelta = int128(int256(gbpfIn));
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }
}
