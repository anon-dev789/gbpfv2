// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @title Minimal interface for Spark's PSM3 on Base.
/// @notice Deployed at 0x1601843c5E9bC251A3272907010AFa41Fa18347E on Base mainnet.
///         Custodies USDC, USDS and sUSDS. Swaps between any pair at the SSRAuthOracle
///         conversion rate with NO fee.
///         Source: github.com/sparkdotfi/spark-psm
interface IPSM3 {
    /// @notice Swap `amountIn` of `assetIn` for `assetOut`, sending the output to `receiver`.
    /// @param  assetIn       Token being deposited into the PSM (must be one of USDC/USDS/sUSDS).
    /// @param  assetOut      Token being requested.
    /// @param  amountIn      Amount of assetIn to deposit (in assetIn's native decimals).
    /// @param  minAmountOut  Reverts if the PSM would output less than this (slippage guard).
    /// @param  receiver      Address to receive assetOut.
    /// @param  referralCode  Spark's optional indexing tag. Pass 0.
    /// @return amountOut     Actual amountOut delivered.
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountOut);

    /// @notice Swap such that exactly `amountOut` of `assetOut` is sent to `receiver`.
    /// @param  maxAmountIn  Reverts if the PSM would consume more than this of assetIn.
    /// @return amountIn     Actual amountIn consumed.
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountIn);

    /// @notice Quote amountOut for a given amountIn. Read-only.
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice Quote amountIn required for a given amountOut. Read-only.
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);
}
