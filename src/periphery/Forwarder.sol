// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IForwarderFactory {
    function depositToken() external view returns (address);
}

/// @title Forwarder
/// @notice One-per-user deterministic deposit sink for the forwarder-based batchers.
///
///         A user's deposit address is `CREATE2(factory, salt = user, this contract's initcode)`,
///         so funds that land there are provably attributable to that user — the address itself
///         IS the receipt. The user does nothing but a plain token transfer to that address (no
///         approve, no contract call); attribution is enforced by the address derivation, which
///         the factory can recompute and verify on-chain.
///
///         Deployed by the factory. On construction — and on every later `flush()` — it sends its
///         entire balance of the factory's deposit token back to the factory, which credits the
///         user this address encodes. Deployed once per user, flushed thereafter (so the address
///         is reused across batches).
///
///         Security: this contract can ONLY ever move funds to its deployer (the factory). Only
///         the factory, using this exact initcode and the user's salt, can produce this address,
///         so no one can deploy different code here or redirect the funds.
contract Forwarder {
    using SafeTransferLib for address;

    address public immutable FACTORY;

    error OnlyFactory();

    constructor() {
        FACTORY = msg.sender;
        // Sweep whatever was sent here before deployment straight to the factory.
        _flushTo(msg.sender);
    }

    /// @notice Sweep this address's deposit-token balance to the factory. Factory-only.
    function flush() external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _flushTo(FACTORY);
    }

    function _flushTo(address factory) internal {
        address token = IForwarderFactory(factory).depositToken();
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal > 0) token.safeTransfer(factory, bal);
    }
}
