// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookMiner} from "../script/HookMiner.sol";

contract HookMinerTest is Test {
    /// Foundry's default CREATE2 deployer.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Required flags for our hook: BEFORE_SWAP_FLAG (1<<7) | BEFORE_SWAP_RETURNS_DELTA_FLAG (1<<3).
    uint160 internal constant REQUIRED_FLAGS = (1 << 7) | (1 << 3); // = 0x88

    function test_find_returns_salt_satisfying_flags() public pure {
        // Use a placeholder init code; the miner doesn't care about contents, only hash.
        bytes memory initCode = hex"60806040";

        (bytes32 salt, address addr) = HookMiner.find(CREATE2_DEPLOYER, REQUIRED_FLAGS, initCode, 0, 1_000_000);

        // Verify the resulting address has exactly the required flag bits in its low 14 bits.
        assertEq(uint160(addr) & 0x3fff, REQUIRED_FLAGS, "flags mismatch");

        // Verify the computed address matches what we'd derive independently.
        bytes32 initCodeHash = keccak256(initCode);
        address derived = HookMiner.computeAddress(CREATE2_DEPLOYER, salt, initCodeHash);
        assertEq(derived, addr, "address derivation inconsistent");
    }

    function test_find_no_other_flag_bits_set() public pure {
        bytes memory initCode = hex"60806040";
        (, address addr) = HookMiner.find(CREATE2_DEPLOYER, REQUIRED_FLAGS, initCode, 0, 1_000_000);

        // The low 14 bits should equal exactly REQUIRED_FLAGS — no extra flag bits.
        uint160 lowBits = uint160(addr) & 0x3fff;
        assertEq(lowBits, REQUIRED_FLAGS);

        // Specifically check that no other V4 hook bits are set:
        // BEFORE_INITIALIZE (1<<13), AFTER_INITIALIZE (1<<12),
        // BEFORE_ADD_LIQUIDITY (1<<11), AFTER_ADD_LIQUIDITY (1<<10),
        // BEFORE_REMOVE_LIQUIDITY (1<<9), AFTER_REMOVE_LIQUIDITY (1<<8),
        // BEFORE_SWAP (1<<7) — required,
        // AFTER_SWAP (1<<6), BEFORE_DONATE (1<<5), AFTER_DONATE (1<<4),
        // BEFORE_SWAP_RETURNS_DELTA (1<<3) — required,
        // AFTER_SWAP_RETURNS_DELTA (1<<2), AFTER_ADD_LIQUIDITY_RETURNS_DELTA (1<<1),
        // AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA (1<<0).
        uint160 disallowedBits = (1 << 13) | (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 6)
            | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | (1 << 0);
        assertEq(uint160(addr) & disallowedBits, 0, "disallowed hook flag bit is set");
    }

    function test_find_revertsWhenLimitExceeded() public {
        bytes memory initCode = hex"60806040";
        // Use a low iteration limit with a hard flag requirement (all 14 bits set). The
        // probability of a random CREATE2 address hitting that in 10 iterations is ~10 * 2^-14
        // ≈ 0.06%, so we should reliably hit SaltNotFound.
        // The cheatcode requires the revert to bubble to a known depth; wrap the library call
        // in an external view function so the revert is at depth 1.
        try this.callFind(CREATE2_DEPLOYER, 0x3fff, initCode, 0, 10) {
            revert("expected SaltNotFound revert");
        } catch (bytes memory data) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 32))
            }
            assertEq(selector, HookMiner.SaltNotFound.selector, "wrong revert selector");
        }
    }

    /// External wrapper so try/catch can capture the revert at a known depth.
    function callFind(address deployer, uint160 flags, bytes memory initCode, uint256 startSalt, uint256 limit)
        external
        pure
        returns (bytes32, address)
    {
        return HookMiner.find(deployer, flags, initCode, startSalt, limit);
    }
}
