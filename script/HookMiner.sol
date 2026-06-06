// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @title HookMiner
/// @notice Deterministic CREATE2 salt miner for Uniswap V4 hooks.
///
///         V4 requires that a hook contract's address encodes its hook permissions in the
///         low 14 bits. For our hook, BEFORE_SWAP_FLAG (bit 7 = 0x80) and
///         BEFORE_SWAP_RETURNS_DELTA_FLAG (bit 3 = 0x08) must be set, and all other hook bits
///         in the low 14 bits must be clear.
///
///         This library iterates salts until it finds one that produces a CREATE2 address
///         satisfying that constraint. It's deploy-time tooling; the protocol itself does not
///         depend on this library at runtime.
library HookMiner {
    /// @dev The mask covers all 14 hook flag bits per V4's address-encoding scheme.
    uint160 internal constant FLAG_MASK = 0x3fff;

    /// @notice Find a salt that produces an address satisfying `(addr & FLAG_MASK) == flags`.
    /// @param  deployer       The CREATE2 deployer that will perform the deployment.
    /// @param  flags          Required flag bits.
    /// @param  initCode       The contract creation code (creationCode ++ abi.encode(constructorArgs)).
    /// @param  startSalt      Salt to start iterating from. 0 is fine for fresh searches; pass
    ///                        a non-zero value to resume a search that was interrupted.
    /// @param  iterationLimit Maximum salts to try. Reverts SaltNotFound if exceeded — fail
    ///                        visibly rather than infinite-loop. 1_000_000 is plenty for our
    ///                        2-bit constraint (expected mining cost ~ 2^14 ≈ 16k iterations).
    /// @return salt           A salt satisfying the flag mask.
    /// @return hookAddress    The CREATE2 address that will result from deploying with `salt`.
    function find(address deployer, uint160 flags, bytes memory initCode, uint256 startSalt, uint256 iterationLimit)
        internal
        pure
        returns (bytes32 salt, address hookAddress)
    {
        bytes32 initCodeHash = keccak256(initCode);
        unchecked {
            for (uint256 i = 0; i < iterationLimit; ++i) {
                uint256 candidate = startSalt + i;
                address addr = _computeCreate2Address(deployer, bytes32(candidate), initCodeHash);
                if ((uint160(addr) & FLAG_MASK) == flags) {
                    return (bytes32(candidate), addr);
                }
            }
        }
        revert SaltNotFound(startSalt, iterationLimit);
    }

    /// @notice Compute the CREATE2 address for given `deployer`, `salt`, and `initCodeHash`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return _computeCreate2Address(deployer, salt, initCodeHash);
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        private
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    error SaltNotFound(uint256 startSalt, uint256 iterationLimit);
}
