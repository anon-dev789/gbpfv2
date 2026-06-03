// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Test double for the Spark SSRAuthOracle.
///
///      Models the real two-function behaviour exposed by Spark's oracle on Base:
///      - getChi(): returns the raw stored chi (last bridge update), unchanged between
///        bridge messages.
///      - getConversionRate(): returns the extrapolated chi, ticking every block based on
///        SSR × elapsed time since rho.
///
///      Tests can set the storedChi directly (mimicking a bridge message) and call
///      setConversionRate to drive the "live" rate the Vault reads. This makes it possible to
///      exercise the case where getChi() lags getConversionRate(), which is the regime in
///      production.
contract MockSSRAuthOracle is ISSRAuthOracle {
    uint256 public storedChi;
    uint256 public conversionRate;

    constructor(uint256 initialChi) {
        storedChi = initialChi;
        conversionRate = initialChi;
    }

    /// @notice Set both storedChi and conversionRate to the same value. Models a fresh bridge
    ///         update with no subsequent extrapolation drift.
    function setChi(uint256 newChi) external {
        storedChi = newChi;
        conversionRate = newChi;
    }

    /// @notice Set only the conversion rate. Models the local extrapolation moving forward
    ///         between bridge updates.
    function setConversionRate(uint256 newRate) external {
        conversionRate = newRate;
    }

    function getChi() external view returns (uint256) {
        return storedChi;
    }

    function getConversionRate() external view returns (uint256) {
        return conversionRate;
    }

    function getSSR() external pure returns (uint256) {
        // Returns the neutral value: 1 ray = no rate accrual. Tests that care about SSR can
        // override via a richer mock or via vm.mockCall.
        return 1e27;
    }

    function getRho() external pure returns (uint256) {
        return 0;
    }
}
