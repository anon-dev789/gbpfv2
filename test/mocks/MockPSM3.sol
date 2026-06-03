// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IPSM3} from "../../src/interfaces/IPSM3.sol";

interface IMintableERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

/// @dev Test double for Spark's PSM3. Converts between USDS and sUSDS at a rate set externally.
///      Rate is "USDS per sUSDS" in ray (1e27), matching SSRAuthOracle semantics.
///      No fees, no liquidity bound (mints sUSDS / USDS as needed via the mock token mint hooks).
contract MockPSM3 is IPSM3 {
    address public immutable USDS;
    address public immutable SUSDS;
    uint256 public rate; // ray; USDS per sUSDS

    constructor(address usds_, address sUsds_, uint256 initialRate) {
        USDS = usds_;
        SUSDS = sUsds_;
        rate = initialRate;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (assetIn == USDS && assetOut == SUSDS) {
            // USDS in → sUSDS out: amountOut = amountIn * RAY / rate
            return amountIn * 1e27 / rate;
        }
        if (assetIn == SUSDS && assetOut == USDS) {
            // sUSDS in → USDS out: amountOut = amountIn * rate / RAY
            return amountIn * rate / 1e27;
        }
        revert("unsupported pair");
    }

    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn)
    {
        if (assetIn == USDS && assetOut == SUSDS) {
            // need amountOut sUSDS, so amountIn = ceil(amountOut * rate / RAY)
            return (amountOut * rate + 1e27 - 1) / 1e27;
        }
        if (assetIn == SUSDS && assetOut == USDS) {
            return (amountOut * 1e27 + rate - 1) / rate;
        }
        revert("unsupported pair");
    }

    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256
    ) external returns (uint256 amountOut) {
        amountOut = this.previewSwapExactIn(assetIn, assetOut, amountIn);
        require(amountOut >= minAmountOut, "PSM minOut");
        IMintableERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        // Mint to receiver — simulates an unlimited-liquidity PSM.
        IMintableERC20(assetOut).mint(receiver, amountOut);
    }

    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256
    ) external returns (uint256 amountIn) {
        amountIn = this.previewSwapExactOut(assetIn, assetOut, amountOut);
        require(amountIn <= maxAmountIn, "PSM maxIn");
        IMintableERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        IMintableERC20(assetOut).mint(receiver, amountOut);
    }
}
