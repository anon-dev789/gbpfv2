// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {GBPF} from "../src/GBPF.sol";

contract GBPFTest is Test {
    GBPF internal token;
    address internal hook;
    address internal alice;
    address internal bob;

    function setUp() public {
        hook = makeAddr("hook");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token = new GBPF();
        token.initialize(hook);
    }

    // ============================================================
    // Metadata
    // ============================================================

    function test_name() public view {
        assertEq(token.name(), "GBP Float");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "GBPF");
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_initial_supply_is_zero() public view {
        assertEq(token.totalSupply(), 0);
    }

    function test_hook_address_immutable() public view {
        assertEq(token.HOOK(), hook);
    }

    // ============================================================
    // initialize()
    // ============================================================

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(GBPF.AlreadyInitialized.selector);
        token.initialize(makeAddr("other"));
    }

    function test_initialize_revertsOnZeroAddress() public {
        GBPF fresh = new GBPF();
        vm.expectRevert(GBPF.ZeroHook.selector);
        fresh.initialize(address(0));
    }

    function test_mint_revertsBeforeInitialize() public {
        GBPF fresh = new GBPF();
        vm.expectRevert(GBPF.NotInitialized.selector);
        fresh.mint(alice, 1e18);
    }

    function test_burn_revertsBeforeInitialize() public {
        GBPF fresh = new GBPF();
        vm.expectRevert(GBPF.NotInitialized.selector);
        fresh.burn(1e18);
    }

    // ============================================================
    // Mint access control
    // ============================================================

    function test_mint_by_hook_succeeds() public {
        vm.prank(hook);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_mint_by_random_address_reverts() public {
        vm.expectRevert(GBPF.NotHook.selector);
        token.mint(alice, 100e18);
    }

    function test_mint_by_alice_reverts() public {
        vm.prank(alice);
        vm.expectRevert(GBPF.NotHook.selector);
        token.mint(alice, 100e18);
    }

    function test_mint_to_zero_address_reverts() public {
        // Solady's _mint *permits* minting to address(0), so we add an explicit guard at
        // our wrapper. This test exercises that guard.
        vm.prank(hook);
        vm.expectRevert(GBPF.MintToZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    // ============================================================
    // Burn access control
    // ============================================================

    function test_burn_by_hook_from_self_succeeds() public {
        // Hook mints to itself, then burns from itself.
        vm.startPrank(hook);
        token.mint(hook, 100e18);
        token.burn(40e18);
        vm.stopPrank();
        assertEq(token.balanceOf(hook), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function test_burn_by_random_address_reverts() public {
        vm.prank(hook);
        token.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(GBPF.NotHook.selector);
        token.burn(1e18);
    }

    function test_burn_more_than_hook_balance_reverts() public {
        vm.prank(hook);
        token.mint(hook, 50e18);
        vm.prank(hook);
        vm.expectRevert();
        token.burn(51e18);
    }

    function test_burn_zero_succeeds() public {
        // A zero burn is a no-op but should not revert (consistent with standard ERC20 transfer
        // semantics).
        vm.prank(hook);
        token.burn(0);
        assertEq(token.totalSupply(), 0);
    }

    // ============================================================
    // Transfer (standard ERC20 behaviour)
    // ============================================================

    function test_transfer_works() public {
        vm.prank(hook);
        token.mint(alice, 100e18);
        vm.prank(alice);
        // Safety: GBPF (Solady ERC20) reverts on failure rather than returning false;
        // we assert post-state below.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_transferFrom_with_approval_works() public {
        vm.prank(hook);
        token.mint(alice, 100e18);
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.approve(bob, 50e18);
        vm.prank(bob);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, bob, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(bob), 30e18);
        assertEq(token.allowance(alice, bob), 20e18);
    }

    function test_transfer_exceeds_balance_reverts() public {
        vm.prank(hook);
        token.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 101e18);
    }

    // ============================================================
    // Permit (EIP-2612)
    // ============================================================

    function test_permit_grants_allowance() public {
        // Use a real-ish key so we can sign a permit.
        uint256 aliceKey = 0xA11CE;
        address aliceAddr = vm.addr(aliceKey);

        vm.prank(hook);
        token.mint(aliceAddr, 100e18);

        uint256 nonce = token.nonces(aliceAddr);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 75e18;

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, aliceAddr, bob, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        token.permit(aliceAddr, bob, value, deadline, v, r, s);

        assertEq(token.allowance(aliceAddr, bob), value);
        assertEq(token.nonces(aliceAddr), nonce + 1);
    }

    function test_permit_with_bad_signature_reverts() public {
        uint256 aliceKey = 0xA11CE;
        address aliceAddr = vm.addr(aliceKey);

        uint256 deadline = block.timestamp + 1 hours;

        // Wrong key — should produce a signature that doesn't recover to aliceAddr.
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, aliceAddr, bob, 1e18, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);

        vm.expectRevert();
        token.permit(aliceAddr, bob, 1e18, deadline, v, r, s);
    }

    function test_permit_after_deadline_reverts() public {
        uint256 aliceKey = 0xA11CE;
        address aliceAddr = vm.addr(aliceKey);
        uint256 deadline = block.timestamp - 1; // already past

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, aliceAddr, bob, 1e18, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vm.expectRevert();
        token.permit(aliceAddr, bob, 1e18, deadline, v, r, s);
    }

    // ============================================================
    // Supply tracking under mint/burn sequences
    // ============================================================

    function testFuzz_supply_tracks_mints_and_burns(uint96 a, uint96 b, uint96 c) public {
        vm.startPrank(hook);
        token.mint(alice, a);
        token.mint(hook, b);
        if (c > b) c = b;
        token.burn(c);
        vm.stopPrank();

        assertEq(token.totalSupply(), uint256(a) + uint256(b) - uint256(c));
        assertEq(token.balanceOf(alice), a);
        assertEq(token.balanceOf(hook), uint256(b) - uint256(c));
    }
}
