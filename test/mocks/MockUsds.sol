// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @dev Minimal USDS-like ERC20 for testing. Open mint so tests can seed balances.
contract MockUsds is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock USDS";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSDS";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
