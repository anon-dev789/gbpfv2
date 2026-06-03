// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title GBPF — synthetic GBP token for the GBPF protocol.
/// @notice Standard ERC20 with EIP-2612 permit (inherited from Solady). 18 decimals.
///         Mint and burn are restricted to the hook address — there is no admin and no
///         supply mechanism outside of the protocol's mint/redeem flow.
/// @dev Immutable. No owner, no upgrade, no pause on the token itself (pause is enforced
///      at the hook layer). The token does not freeze, doesn't have blocklists, and does
///      not implement transfer hooks beyond the standard ERC20 contract.
contract GBPF is ERC20 {
    /// @dev The only address authorised to mint and burn GBPF. Hardcoded at deploy.
    address public immutable HOOK;

    error NotHook();
    error MintToZeroAddress();

    constructor(address hook_) {
        HOOK = hook_;
    }

    function name() public pure override returns (string memory) {
        return "GBP Float";
    }

    function symbol() public pure override returns (string memory) {
        return "GBPF";
    }

    /// @notice Mint GBPF to `to`. Hook-only.
    /// @dev The hook calls this during a swap that is a mint operation, after the user's USDS
    ///      has been deposited into the vault. Solady's _mint allows minting to address(0)
    ///      (the resulting tokens would be unrecoverable); we add an explicit guard.
    function mint(address to, uint256 amount) external {
        if (msg.sender != HOOK) revert NotHook();
        if (to == address(0)) revert MintToZeroAddress();
        _mint(to, amount);
    }

    /// @notice Burn GBPF from the hook's own balance. Hook-only.
    /// @dev The hook calls this during a redeem swap, after the user's GBPF has been
    ///      transferred to the hook by the Uniswap V4 PoolManager's settlement flow. The
    ///      token contract enforces the balance check at the burn site (via _burn's
    ///      underlying balance subtraction) — the hook cannot burn GBPF it doesn't hold.
    ///      This avoids needing an allowance for the user→hook leg: V4's swap settlement
    ///      already moves the user's GBPF into the hook's possession as part of the swap
    ///      itself.
    function burn(uint256 amount) external {
        if (msg.sender != HOOK) revert NotHook();
        _burn(msg.sender, amount);
    }
}
