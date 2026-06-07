// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

/// @dev Thin test double for Uniswap V4's PoolManager. Supports:
///      - take / sync / settle (ERC20 flash-accounting from existing PM balance)
///      - mint / burn for ERC-6909 claim tokens
///      - unlock + IUnlockCallback for flush flows
///      - fund(...) to seed token balances for take()
///      - mintClaim(...) to seed 6909 claim balances for burn()
contract MockPoolManager {
    /// @dev Most recently sync'd currency, and the PoolManager's balance at sync time.
    Currency public lastSynced;
    uint256 public lastSyncedBalance;

    /// @dev Accumulated paid-in amount on the most recent settle().
    uint256 public lastSettlePaid;

    /// @dev 6909 claim balances: owner → id → balance.
    mapping(address => mapping(uint256 => uint256)) public claim;

    /// @dev Re-entrance flag for unlock semantics.
    bool internal _locked = true;

    /// @dev Push tokens to the manager so it has something to take().
    function fund(address token, uint256 amount) external {
        IERC20Min(token).mint(address(this), amount);
    }

    /// @dev Seed a 6909 claim directly (test scaffolding).
    function mintClaim(address to, uint256 id, uint256 amount) external {
        claim[to][id] += amount;
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

    /// @notice ERC-6909 mint to credit a 6909 claim balance. Real PM debits the caller's currency
    ///         delta; we don't model the delta system here.
    function mint(address to, uint256 id, uint256 amount) external {
        claim[to][id] += amount;
    }

    /// @notice ERC-6909 burn — reduce the holder's 6909 claim balance.
    function burn(address from, uint256 id, uint256 amount) external {
        require(claim[from][id] >= amount, "MockPM: insufficient 6909");
        claim[from][id] -= amount;
    }

    /// @notice Unlock the manager and invoke the caller's unlockCallback.
    function unlock(bytes calldata data) external returns (bytes memory) {
        _locked = false;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        _locked = true;
        return result;
    }
}
