// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {OracleAdapter} from "../OracleAdapter.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback, INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @title BufferVault
/// @notice Gateway periphery: owns the single LP position in the public V3 GBPF/USDS pool
///         ("Gateway pool") and keeps it pegged to the GBPF primary market. See
///         GATEWAY_DESIGN.md for the full design.
///
///         The vault holds a tight liquidity band centred on the OracleAdapter TWAP. The
///         permissionless `rebalance()`:
///           - exits the band when it has drifted from the oracle (someone swapped) or the
///             oracle price has moved;
///           - pushes any inventory imbalance through the LIVE V4 hook pool (oracle-priced
///             mint/redeem) — this is what makes the Gateway pool "defer" to the hook;
///           - moves the V3 spot price back to the oracle price and re-mints the band.
///         If the oracle is unhealthy the position is withdrawn entirely: the Gateway pool
///         must never quote a stale price while the primary market is paused.
///
///         PERIPHERY, NOT CORE. This contract is not part of the audited immutable core; it
///         holds the operator's working capital and therefore has an owner (deposit by plain
///         transfer; withdraw is owner-only). Market integrity does not depend on the owner:
///         `rebalance()` is permissionless and profitable to call by construction
///         (TRIGGER 50bp > 20bp hook fee + 5bp pool fee), so third parties can keep the pool
///         honest if the operator's keeper dies.
contract BufferVault is IUnlockCallback, IUniswapV3SwapCallback {
    using SafeTransferLib for address;

    // ============================================================================================
    // Immutable configuration
    // ============================================================================================

    address public immutable OWNER;
    IPoolManager public immutable POOL_MANAGER;
    OracleAdapter public immutable ORACLE;
    INonfungiblePositionManager public immutable POSM;
    IUniswapV3Pool public immutable V3_POOL;
    address public immutable GBPF;
    address public immutable USDS;
    address public immutable HOOK;

    /// @dev True iff GBPF sorts below USDS — then GBPF is token0/currency0 in BOTH pools
    ///      (the V3 Gateway pool and the V4 hook pool share the same token pair).
    bool public immutable GBPF_IS_TOKEN0;

    /// @dev V3 pool fee tier and tick spacing (0.05% / 10).
    uint24 internal constant V3_FEE = 500;
    int24 internal constant V3_TICK_SPACING = 10;

    // ============================================================================================
    // Tuning constants (1 tick ≈ 1 bp). Periphery is cheap — retune by redeploying.
    // ============================================================================================

    /// @dev Band half-width around the oracle tick.
    int24 internal constant BAND_TICKS = 30;
    /// @dev Repeg when the V3 spot tick deviates from the oracle tick by more than this.
    ///      Must exceed hook flat fee (20bp) + V3 fee (5bp) so a repeg is never loss-making.
    int24 internal constant TRIGGER_TICKS = 50;
    /// @dev Recentre when the oracle tick has drifted this far from the band centre.
    int24 internal constant RECENTER_TICKS = 15;
    /// @dev Skip the hook swap when the inventory imbalance is below this USDS value —
    ///      paying the 20bp hook fee to shuffle dust is value-negative.
    uint256 internal constant MIN_HOOK_SWAP_USDS = 0.01e18;

    uint256 internal constant WAD = 1e18;

    // ============================================================================================
    // State
    // ============================================================================================

    /// @dev Current V3 position NFT id; 0 when no position is deployed.
    uint256 public positionTokenId;
    /// @dev Liquidity of the current position (tracked locally; no positions() call needed).
    uint128 public positionLiquidity;
    /// @dev Tick the current band was centred on at mint time.
    int24 public positionCenterTick;

    uint256 private _locked = 1;

    // ============================================================================================
    // Events / errors
    // ============================================================================================

    event Rebalanced(int24 oracleTick, int24 spotTickBefore, uint256 tokenId, uint128 liquidity);
    event PositionExited(uint256 tokenId, uint256 gbpfOut, uint256 usdsOut);
    event LiquidityPulledOnPause();
    event HookSwapped(bool isMint, uint256 amountIn, uint256 amountOut);
    event HookSwapFailed(bytes reason);
    event OwnerWithdrawal(address token, uint256 amount, address to);

    error NotOwner();
    error NotPoolManager();
    error NotV3Pool();
    error Reentrancy();
    error NothingToDo();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(
        address owner_,
        address poolManager_,
        address oracle_,
        address posm_,
        address v3Pool_,
        address gbpf_,
        address usds_,
        address hook_
    ) {
        OWNER = owner_;
        POOL_MANAGER = IPoolManager(poolManager_);
        ORACLE = OracleAdapter(oracle_);
        POSM = INonfungiblePositionManager(posm_);
        V3_POOL = IUniswapV3Pool(v3Pool_);
        GBPF = gbpf_;
        USDS = usds_;
        HOOK = hook_;
        GBPF_IS_TOKEN0 = gbpf_ < usds_;

        // One-time max approvals for the position manager (it pulls both tokens on mint).
        gbpf_.safeApprove(posm_, type(uint256).max);
        usds_.safeApprove(posm_, type(uint256).max);
    }

    // ============================================================================================
    // Rebalance — the deferral engine
    // ============================================================================================

    /// @notice Permissionless. Brings the Gateway pool back in line with the primary market.
    ///         No-ops (cheap revert) when the band is already centred and the spot is within
    ///         tolerance, so it can be called blindly on a heartbeat.
    function rebalance() external nonReentrant {
        (uint256 twapWad, bool healthy,) = ORACLE.update();

        // Oracle paused → the primary market is closed; never quote a stale price. Pull all
        // Gateway liquidity. The next healthy rebalance() restores it.
        if (!healthy) {
            if (positionTokenId == 0) revert NothingToDo();
            _exitPosition();
            emit LiquidityPulledOnPause();
            return;
        }

        uint160 oracleSqrt = _sqrtPriceX96FromTwap(twapWad);
        int24 oracleTick = TickMath.getTickAtSqrtPrice(oracleSqrt);
        (, int24 spotTick,,,,,) = V3_POOL.slot0();

        bool hasPosition = positionTokenId != 0;
        bool repeg = hasPosition && _absDiff(spotTick, oracleTick) > TRIGGER_TICKS;
        bool recenter = hasPosition && _absDiff(positionCenterTick, oracleTick) > RECENTER_TICKS;
        bool seed = !hasPosition
            && (IERC20Like(GBPF).balanceOf(address(this)) > 0 || IERC20Like(USDS).balanceOf(address(this)) > 0);
        if (!repeg && !recenter && !seed) revert NothingToDo();

        // 1. Pull the band (if any). All inventory is now loose GBPF + USDS in this contract.
        if (hasPosition) _exitPosition();

        // 2. Push the inventory imbalance through the hook: excess USDS → mint GBPF; excess
        //    GBPF → redeem to USDS. Both at the primary market's oracle price. Best-effort:
        //    a failing hook swap (e.g. redeem before flush() has converted backing) must not
        //    leave the Gateway liquidity stranded outside the pool — we re-mint regardless
        //    and the next rebalance retries the swap.
        _balanceInventoryViaHook(twapWad);

        // 3. Move the V3 spot price onto the oracle price, then re-mint the band around it.
        //    Atomic with the mint, so mins are not needed on the mint (nothing can interleave).
        _slideSpotTo(oracleSqrt);
        _mintBand(oracleTick);

        emit Rebalanced(oracleTick, spotTick, positionTokenId, positionLiquidity);
    }

    // ============================================================================================
    // Owner — capital in/out. Deposits are plain token transfers to this address.
    // ============================================================================================

    /// @notice Exit the V3 position (if any) and send the full GBPF + USDS inventory to `to`.
    function exitAndWithdrawAll(address to) external onlyOwner nonReentrant {
        if (positionTokenId != 0) _exitPosition();
        uint256 gbpfBal = IERC20Like(GBPF).balanceOf(address(this));
        uint256 usdsBal = IERC20Like(USDS).balanceOf(address(this));
        if (gbpfBal > 0) GBPF.safeTransfer(to, gbpfBal);
        if (usdsBal > 0) USDS.safeTransfer(to, usdsBal);
        emit OwnerWithdrawal(GBPF, gbpfBal, to);
        emit OwnerWithdrawal(USDS, usdsBal, to);
    }

    /// @notice Withdraw `amount` of any token (also serves as rescue for strays).
    function withdrawToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        token.safeTransfer(to, amount);
        emit OwnerWithdrawal(token, amount, to);
    }

    // ============================================================================================
    // Internals — V3 position management
    // ============================================================================================

    function _exitPosition() internal {
        uint256 tokenId = positionTokenId;
        POSM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: positionLiquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        (uint256 amount0, uint256 amount1) = POSM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        POSM.burn(tokenId);
        positionTokenId = 0;
        positionLiquidity = 0;

        (uint256 gbpfOut, uint256 usdsOut) = GBPF_IS_TOKEN0 ? (amount0, amount1) : (amount1, amount0);
        emit PositionExited(tokenId, gbpfOut, usdsOut);
    }

    function _mintBand(int24 oracleTick) internal {
        uint256 gbpfBal = IERC20Like(GBPF).balanceOf(address(this));
        uint256 usdsBal = IERC20Like(USDS).balanceOf(address(this));
        if (gbpfBal == 0 && usdsBal == 0) return;

        int24 center = _floorToSpacing(oracleTick);
        int24 tickLower = _floorToSpacing(oracleTick - BAND_TICKS);
        int24 tickUpper = _ceilToSpacing(oracleTick + BAND_TICKS);

        (uint256 amount0Desired, uint256 amount1Desired) = GBPF_IS_TOKEN0 ? (gbpfBal, usdsBal) : (usdsBal, gbpfBal);

        // Mins are 0: the spot was set to the oracle price in this same transaction, so the
        // mint ratio cannot be manipulated between the slide and the mint.
        (uint256 tokenId, uint128 liquidity,,) = POSM.mint(
            INonfungiblePositionManager.MintParams({
                token0: GBPF_IS_TOKEN0 ? GBPF : USDS,
                token1: GBPF_IS_TOKEN0 ? USDS : GBPF,
                fee: V3_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        positionTokenId = tokenId;
        positionLiquidity = liquidity;
        positionCenterTick = center;
    }

    /// @dev Move the V3 spot price to `targetSqrt` with a 1-wei exact-input swap. When this
    ///      vault is the pool's only LP (the expected state — its position was just exited),
    ///      the book is empty and the price slides to the limit while consuming ~nothing. If
    ///      third-party LPs exist, the 1-wei cap means the spot barely moves — acceptable,
    ///      because then the pool has its own price discovery and the band mint below still
    ///      centres on the oracle.
    function _slideSpotTo(uint160 targetSqrt) internal {
        (uint160 currentSqrt,,,,,,) = V3_POOL.slot0();
        if (currentSqrt == targetSqrt) return;
        bool zeroForOne = currentSqrt > targetSqrt;
        // Clamp inside V3's open interval bounds.
        if (targetSqrt <= TickMath.MIN_SQRT_PRICE) targetSqrt = TickMath.MIN_SQRT_PRICE + 1;
        if (targetSqrt >= TickMath.MAX_SQRT_PRICE) targetSqrt = TickMath.MAX_SQRT_PRICE - 1;
        V3_POOL.swap(address(this), zeroForOne, int256(1), targetSqrt, "");
    }

    /// @dev V3 swap callback: pay what the pool says we owe (≤ 1 wei from _slideSpotTo).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(V3_POOL)) revert NotV3Pool();
        address token0 = GBPF_IS_TOKEN0 ? GBPF : USDS;
        address token1 = GBPF_IS_TOKEN0 ? USDS : GBPF;
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ============================================================================================
    // Internals — hook (primary market) swaps
    // ============================================================================================

    function _balanceInventoryViaHook(uint256 twapWad) internal {
        uint256 gbpfBal = IERC20Like(GBPF).balanceOf(address(this));
        uint256 usdsBal = IERC20Like(USDS).balanceOf(address(this));
        uint256 gbpfValueUsds = FixedPointMathLib.mulWad(gbpfBal, twapWad);

        bool isMint;
        uint256 amountIn;
        if (usdsBal > gbpfValueUsds) {
            // USDS-heavy → mint GBPF with half the excess so post-swap value is ~50/50.
            uint256 excess = (usdsBal - gbpfValueUsds) / 2;
            if (excess < MIN_HOOK_SWAP_USDS) return;
            (isMint, amountIn) = (true, excess);
        } else {
            uint256 excessValue = (gbpfValueUsds - usdsBal) / 2;
            if (excessValue < MIN_HOOK_SWAP_USDS) return;
            (isMint, amountIn) = (false, FixedPointMathLib.mulDiv(excessValue, WAD, twapWad));
        }

        // Mint = USDS→GBPF runs zeroForOne when USDS is currency0 (hook convention).
        bool usdsIsCurrency0 = !GBPF_IS_TOKEN0;
        bool zeroForOne = isMint ? usdsIsCurrency0 : !usdsIsCurrency0;
        bytes memory data = abi.encode(zeroForOne, amountIn);

        uint256 outBefore = isMint ? IERC20Like(GBPF).balanceOf(address(this)) : usdsBal;
        try POOL_MANAGER.unlock(data) {
            uint256 outAfter =
                isMint ? IERC20Like(GBPF).balanceOf(address(this)) : IERC20Like(USDS).balanceOf(address(this));
            emit HookSwapped(isMint, amountIn, outAfter - outBefore);
        } catch (bytes memory reason) {
            // E.g. redeem before flush() has realised backing. Re-minting the band still
            // proceeds; the next rebalance retries.
            emit HookSwapFailed(reason);
        }
    }

    /// @dev V4 unlock callback: execute the hook-pool swap and settle both legs.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (bool zeroForOne, uint256 amountIn) = abi.decode(data, (bool, uint256));

        PoolKey memory key = _hookPoolKey();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(amountIn); // exact input; bounded by inventory ≪ int256 max
        BalanceDelta delta = POOL_MANAGER.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}), ""
        );

        _settleLeg(key.currency0, delta.amount0());
        _settleLeg(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Delta from this contract's (the swapper's) perspective:
    ///        negative → we owe the PoolManager (sync + transfer + settle)
    ///        positive → the PoolManager owes us (take)
    function _settleLeg(Currency currency, int128 amount) internal {
        if (amount == 0) return;
        if (amount < 0) {
            uint256 value = uint256(uint128(-amount));
            POOL_MANAGER.sync(currency);
            Currency.unwrap(currency).safeTransfer(address(POOL_MANAGER), value);
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _hookPoolKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) =
            GBPF_IS_TOKEN0 ? (Currency.wrap(GBPF), Currency.wrap(USDS)) : (Currency.wrap(USDS), Currency.wrap(GBPF));
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(HOOK)});
    }

    // ============================================================================================
    // Internals — math helpers
    // ============================================================================================

    /// @dev Oracle TWAP (USDS per GBPF, WAD) → V3 sqrtPriceX96 for the Gateway pool's token
    ///      ordering. price = token1/token0; both tokens are 18-decimal so no scaling beyond
    ///      the WAD divide. sqrtPriceX96 = sqrt(priceWad/1e18) * 2^96 = sqrt(priceWad) * 2^96 / 1e9.
    function _sqrtPriceX96FromTwap(uint256 twapWad) internal view returns (uint160) {
        uint256 priceWad = GBPF_IS_TOKEN0 ? twapWad : FixedPointMathLib.mulDiv(WAD, WAD, twapWad);
        uint256 result = (FixedPointMathLib.sqrt(priceWad) << 96) / 1e9;
        require(result > TickMath.MIN_SQRT_PRICE && result < TickMath.MAX_SQRT_PRICE, "sqrt price out of range");
        // Safety: bounds-checked against MAX_SQRT_PRICE (< 2^160) on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a - b : b - a;
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 spaced = (tick / V3_TICK_SPACING) * V3_TICK_SPACING;
        if (tick < 0 && tick % V3_TICK_SPACING != 0) spaced -= V3_TICK_SPACING;
        return spaced;
    }

    function _ceilToSpacing(int24 tick) internal pure returns (int24) {
        int24 floored = _floorToSpacing(tick);
        return floored == tick ? tick : floored + V3_TICK_SPACING;
    }

    /// @dev Accept V3 position NFTs (NonfungiblePositionManager mints with _mint, but be safe).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
