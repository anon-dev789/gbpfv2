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
///
///      HOOK is set once via initialize() during deployment because of the circular deploy
///      dependency: the Hook's CREATE2 address must encode V4 flag bits, and its constructor
///      takes the GBPF address. See DEPLOY_DESIGN.md.
contract GBPF is ERC20 {
    /// @dev The only address authorised to mint and burn GBPF. Set once via initialize().
    address public HOOK;

    /// @dev Standard "burn" address used to lock the dust mint forever.
    address internal constant DUST_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Dust mint at deploy ensures totalSupply > 0 from genesis. This eliminates the
    ///      chicken-and-egg in bootstrapping: the Hook's solvency math has a `totalSupply == 0`
    ///      revert guard (avoids divide-by-zero), but the first mint via the Hook would
    ///      otherwise trip that guard. By minting 1 wei to a permanently-locked address in the
    ///      constructor, totalSupply is non-zero from the moment the contract exists, so the
    ///      first real user mint via the Hook proceeds normally.
    uint256 internal constant DUST_AMOUNT = 1;

    error NotHook();
    error MintToZeroAddress();
    error AlreadyInitialized();
    error ZeroHook();
    error NotInitialized();

    constructor() {
        // Mint dust to the burn address. _mint is internal-only; not gated by HOOK.
        _mint(DUST_BURN_ADDRESS, DUST_AMOUNT);
    }

    /// @notice One-shot setter for the Hook address. After this call, HOOK is fixed forever.
    /// @dev    Reverts if called twice or with the zero address.
    function initialize(address hook_) external {
        if (HOOK != address(0)) revert AlreadyInitialized();
        if (hook_ == address(0)) revert ZeroHook();
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
        if (HOOK == address(0)) revert NotInitialized();
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
        if (HOOK == address(0)) revert NotInitialized();
        if (msg.sender != HOOK) revert NotHook();
        _burn(msg.sender, amount);
    }
}
