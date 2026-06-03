// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Test double for the Spark SSRAuthOracle. Lets tests advance `chi` directly without
///      having to model the per-second SSR extrapolation. `chi` is the only field the Vault
///      reads through the interface (getChi / getConversionRate both return it here).
contract MockSSRAuthOracle is ISSRAuthOracle {
    uint256 public chi;

    constructor(uint256 initialChi) {
        chi = initialChi;
    }

    function setChi(uint256 newChi) external {
        chi = newChi;
    }

    function bumpChi(uint256 delta) external {
        chi += delta;
    }

    function getChi() external view returns (uint256) {
        return chi;
    }

    function getConversionRate() external view returns (uint256) {
        return chi;
    }

    function getSSR() external pure returns (uint256) {
        return 0;
    }

    function getRho() external pure returns (uint256) {
        return 0;
    }
}
