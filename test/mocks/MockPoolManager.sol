// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

/// @dev Thin test double for Uniswap V4's PoolManager. We only need the three flash-accounting
///      functions the hook calls: take, sync, settle. Plus a "synced balance" tracker so settle
///      computes the right delta.
///
///      This mock does not enforce flash-accounting reconciliation — it just lets the hook's
///      token-movement code run end-to-end. Tests inspect token balances afterwards to verify
///      the hook moved the right amounts.
contract MockPoolManager {
    /// @dev Most recently sync'd currency, and the PoolManager's balance at sync time.
    Currency public lastSynced;
    uint256 public lastSyncedBalance;

    /// @dev Accumulated paid-in amount on the most recent settle().
    uint256 public lastSettlePaid;

    /// @dev Push tokens to the manager so it has something to take().
    function fund(address token, uint256 amount) external {
        IERC20Min(token).mint(address(this), amount);
    }

    function take(Currency currency, address to, uint256 amount) external {
        IERC20Min(Currency.unwrap(currency)).transfer(to, amount);
    }

    function sync(Currency currency) external {
        lastSynced = currency;
        lastSyncedBalance = IERC20Min(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        uint256 current = IERC20Min(Currency.unwrap(lastSynced)).balanceOf(address(this));
        paid = current - lastSyncedBalance;
        lastSettlePaid = paid;
    }
}
