// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev Minimal interface for the V4 Quoter on Base.
///      quoteExactInputSingle returns (amountOut, gasEstimate).
interface IQuoterV4 {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @dev Fork test: proves the live GBPF V4 hook pool is simulatable by the canonical Uniswap
///      V4 Quoter deployed on Base. This is the artifact required for the Uniswap hook listing
///      application (https://github.com/Uniswap/hooklist).
///
///      Tests both directions:
///        mint  — USDS→GBPF (zeroForOne = false, GBPF is currency0)
///        redeem — GBPF→USDS (zeroForOne = true)
///
///      Run against the LIVE deployed contracts (no local redeploy):
///        BASE_RPC_URL=<rpc> forge test --match-contract QuoterForkTest -vvv --fork-url <rpc>
///
///      Or via the fork-tests profile:
///        forge test --match-contract QuoterForkTest --no-match-contract 'Unit|Invariant' \
///          -vvv --rpc-url https://mainnet.base.org
contract QuoterForkTest is Test {
    // Pin to a recent block — update if the test becomes stale.
    uint256 internal constant BASE_FORK_BLOCK = 47_200_000;

    // Live deployed contracts (commit 60d3895, DEPLOYMENT.md).
    address internal constant HOOK = 0x5613c279E8Db9815DBD0CdFbd10515EAbD350088;
    address internal constant GBPF = 0x1817FD23ceF7Da47DF934fdc880d72e653786770;
    address internal constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant PM = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;

    PoolKey internal poolKey;
    IQuoterV4 internal quoter;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        quoter = IQuoterV4(QUOTER);

        // Canonical PoolKey (GBPF is currency0 — lower address than USDS).
        poolKey = PoolKey({
            currency0: Currency.wrap(GBPF), currency1: Currency.wrap(USDS), fee: 0, tickSpacing: 1, hooks: IHooks(HOOK)
        });
    }

    /// @dev Mint direction: USDS→GBPF. zeroForOne=false (selling currency1 USDS for currency0 GBPF).
    ///      Proves the Quoter can simulate a mint against the live hook.
    function test_quoter_simulates_mint_usds_to_gbpf() public {
        uint128 exactUsdsIn = 100e18; // 100 USDS

        (uint256 gbpfOut, uint256 gasEst) = quoter.quoteExactInputSingle(
            IQuoterV4.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // USDS (currency1) → GBPF (currency0)
                exactAmount: exactUsdsIn,
                hookData: ""
            })
        );

        // At ~1.34 USDS/GBPF and 20bp fee, 100 USDS should yield 73–76 GBPF.
        assertGt(gbpfOut, 70e18, "Quoter: mint output implausibly low");
        assertLt(gbpfOut, 80e18, "Quoter: mint output implausibly high");
        assertGt(gasEst, 0, "Quoter: gas estimate zero");

        emit log_named_decimal_uint("GBPF out for 100 USDS", gbpfOut, 18);
        emit log_named_uint("gas estimate", gasEst);
    }

    /// @dev Redeem direction: GBPF→USDS. zeroForOne=true (selling currency0 GBPF for currency1 USDS).
    ///      Proves the Quoter can simulate a redeem against the live hook.
    ///      Amount is constrained to what the live vault can back: seed was 1 USDS → ~0.91 sUSDS
    ///      principal after fees/yield. 0.5 GBPF needs ~0.67 USDS — safely within backing.
    function test_quoter_simulates_redeem_gbpf_to_usds() public {
        uint128 exactGbpfIn = 0.5e18; // 0.5 GBPF — within live vault backing

        (uint256 usdsOut, uint256 gasEst) = quoter.quoteExactInputSingle(
            IQuoterV4.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: true, // GBPF (currency0) → USDS (currency1)
                exactAmount: exactGbpfIn,
                hookData: ""
            })
        );

        // At ~1.34 USDS/GBPF and 20bp fee, 0.5 GBPF should yield 0.65–0.68 USDS.
        assertGt(usdsOut, 0.65e18, "Quoter: redeem output implausibly low");
        assertLt(usdsOut, 0.7e18, "Quoter: redeem output implausibly high");
        assertGt(gasEst, 0, "Quoter: gas estimate zero");

        emit log_named_decimal_uint("USDS out for 0.5 GBPF", usdsOut, 18);
        emit log_named_uint("gas estimate", gasEst);
    }
}
