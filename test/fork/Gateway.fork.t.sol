// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BufferVault} from "../../src/periphery/BufferVault.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3SwapCallback,
    INonfungiblePositionManager
} from "../../src/periphery/interfaces/IUniswapV3.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {Vault} from "../../src/Vault.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Minimal V4 unlock-callback router (the proven pattern from Hook.fork.t.sol) so the
///      TEST can mint GBPF for itself at the live hook — needed to create sell-side pressure.
contract TestSwapRouter is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    constructor(address poolManager_) {
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        address payer;
        address recipient;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, address recipient)
        external
        returns (BalanceDelta delta)
    {
        bytes memory data =
            abi.encode(CallbackData({key: key, params: params, payer: msg.sender, recipient: recipient}));
        bytes memory result = POOL_MANAGER.unlock(data);
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "router: only PoolManager");
        CallbackData memory cb = abi.decode(data, (CallbackData));
        BalanceDelta delta = POOL_MANAGER.swap(cb.key, cb.params, "");
        _resolveLeg(cb.key.currency0, delta.amount0(), cb.payer, cb.recipient);
        _resolveLeg(cb.key.currency1, delta.amount1(), cb.payer, cb.recipient);
        return abi.encode(delta);
    }

    function _resolveLeg(Currency currency, int128 amount, address payer, address recipient) internal {
        if (amount == 0) return;
        if (amount < 0) {
            address token = Currency.unwrap(currency);
            uint256 value = uint256(uint128(-amount));
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20Like(token).transferFrom(payer, address(POOL_MANAGER), value);
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, recipient, uint256(uint128(amount)));
        }
    }
}

/// @dev Gateway fork test against the LIVE Base deployment (post-audit redeploy, commit
///      60d3895, bootstrapped). Creates the V3 GBPF/USDS Gateway pool, seeds the BufferVault,
///      and verifies the full lifecycle: seed → trader-induced deviation → permissionless
///      repeg through the live hook → oracle-pause liquidity pull.
contract GatewayForkTest is Test, IUniswapV3SwapCallback {
    /// Must be AFTER the live bootstrap completed (block 47_143_463).
    uint256 internal constant BASE_FORK_BLOCK = 47_150_000;

    // Live core (DEPLOYMENT.md).
    address internal constant ORACLE = 0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F;
    address internal constant GBPF = 0x1817FD23ceF7Da47DF934fdc880d72e653786770;
    address internal constant CORE_VAULT = 0xA9a831a348D0Db372cf75dd7C082cFF67A453498;
    address internal constant HOOK = 0x5613c279E8Db9815DBD0CdFbd10515EAbD350088;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

    // Base V3 infra. POSM address proven by Freehold's working SeedPool deploy.
    address internal constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant POSM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    /// Spark PSM3 — the USDS whale used by the existing fork tests.
    address internal constant USDS_WHALE = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;

    uint24 internal constant V3_FEE = 500;
    int24 internal constant TRIGGER_TICKS = 50;

    IUniswapV3Pool internal pool;
    BufferVault internal buffer;
    TestSwapRouter internal v4Router;
    PoolKey internal hookKey;
    bool internal gbpfIsToken0;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        gbpfIsToken0 = GBPF < USDS;

        // 1. Create + initialise the Gateway pool at the live oracle price.
        address poolAddr = IUniswapV3Factory(V3_FACTORY).createPool(GBPF, USDS, V3_FEE);
        pool = IUniswapV3Pool(poolAddr);
        pool.initialize(_oracleSqrtX96());

        // 2. Deploy the BufferVault against the live core.
        buffer = new BufferVault(address(this), V4_POOL_MANAGER, ORACLE, POSM, poolAddr, GBPF, USDS, HOOK);

        // 3. Fund: 100 USDS to the vault (deposits are plain transfers), 200 USDS to the test
        //    for trader pressure.
        _giveUsds(address(buffer), 100e18);
        _giveUsds(address(this), 200e18);

        // 4. V4 router so the test can mint GBPF at the live hook.
        v4Router = new TestSwapRouter(V4_POOL_MANAGER);
        IERC20Like(USDS).approve(address(v4Router), type(uint256).max);
        IERC20Like(GBPF).approve(address(v4Router), type(uint256).max);
        hookKey = PoolKey({
            currency0: gbpfIsToken0 ? Currency.wrap(GBPF) : Currency.wrap(USDS),
            currency1: gbpfIsToken0 ? Currency.wrap(USDS) : Currency.wrap(GBPF),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(HOOK)
        });
    }

    // ============================================================
    // Seed
    // ============================================================

    function test_seed_rebalance_deploys_band_at_oracle_price() public {
        uint256 corePendingBefore = Vault(CORE_VAULT).pendingUsdsClaim();

        buffer.rebalance();

        // Position exists with real liquidity.
        assertGt(buffer.positionTokenId(), 0, "no position minted");
        assertGt(uint256(pool.liquidity()), 0, "pool has no in-range liquidity");

        // Spot pinned to the oracle tick.
        assertLe(_absDiff(_spotTick(), _oracleTick()), 1, "spot not at oracle after seed");

        // Inventory was balanced by MINTING at the live hook (USDS-only seed → half to GBPF),
        // which must have created a pending USDS claim on the core vault.
        assertGt(Vault(CORE_VAULT).pendingUsdsClaim(), corePendingBefore, "hook mint did not reach core vault");
    }

    function test_rebalance_noop_reverts_when_in_band() public {
        buffer.rebalance();
        vm.expectRevert(BufferVault.NothingToDo.selector);
        buffer.rebalance();
    }

    // ============================================================
    // Repeg: buy pressure (pool drained of GBPF, price pushed up)
    // ============================================================

    function test_repeg_after_buy_pressure() public {
        buffer.rebalance();
        int24 oracleTick = _oracleTick();

        // Trader buys GBPF with 70 USDS exact-in — more than the band's whole GBPF side —
        // sliding the spot up to oracle+200 once the band is consumed.
        _v3Swap(false, 70e18, oracleTick + 200);
        assertGt(_absDiff(_spotTick(), oracleTick), TRIGGER_TICKS, "deviation did not exceed trigger");

        buffer.rebalance();

        assertLe(_absDiff(_spotTick(), _oracleTick()), 1, "spot not repegged to oracle");
        assertGt(uint256(pool.liquidity()), 0, "band not re-minted");
    }

    // ============================================================
    // Repeg: sell pressure (pool drained of USDS) — exercises hook REDEEM
    // ============================================================

    function test_repeg_after_sell_pressure_redeems_via_hook() public {
        buffer.rebalance();

        // Realise the core vault's backing so the hook redeem inside rebalance can pay out.
        Vault(CORE_VAULT).flush();

        // Test mints ~47 GBPF at the live hook, then dumps it on the Gateway pool.
        SwapParams memory mintParams =
            SwapParams({zeroForOne: !gbpfIsToken0, amountSpecified: -int256(60e18), sqrtPriceLimitX96: 0});
        v4Router.swap(hookKey, mintParams, address(this));
        uint256 gbpfHeld = IERC20Like(GBPF).balanceOf(address(this));
        assertGt(gbpfHeld, 0, "test failed to mint GBPF at hook");
        // The test's own mint added a fresh pending claim; flush again so redeem backing is full.
        Vault(CORE_VAULT).flush();

        int24 oracleTick = _oracleTick();
        _v3Swap(true, int256(gbpfHeld), oracleTick - 200);
        assertGt(_absDiff(_spotTick(), oracleTick), TRIGGER_TICKS, "deviation did not exceed trigger");

        uint256 gbpfSupplyBefore = _gbpfTotalSupply();
        uint256 gbpfClaimBefore = Vault(CORE_VAULT).pendingGbpfClaim();
        buffer.rebalance();

        assertLe(_absDiff(_spotTick(), _oracleTick()), 1, "spot not repegged to oracle");
        assertGt(uint256(pool.liquidity()), 0, "band not re-minted");
        // GBPF-heavy inventory → the vault redeemed through the hook. Under the core's
        // deferred-claim design the redeemed GBPF is not burned in the swap itself: the core
        // vault is credited a 6909 GBPF claim, and the burn happens at the next flush().
        assertGt(Vault(CORE_VAULT).pendingGbpfClaim(), gbpfClaimBefore, "hook redeem did not reach core vault");
        Vault(CORE_VAULT).flush();
        assertLt(_gbpfTotalSupply(), gbpfSupplyBefore, "flush did not burn the redeemed GBPF");
    }

    /// @dev Without flush() the hook redeem inside rebalance fails (no realised backing); the
    ///      vault must swallow that and still re-mint the band — never strand liquidity.
    function test_rebalance_survives_hook_redeem_failure() public {
        buffer.rebalance();

        SwapParams memory mintParams =
            SwapParams({zeroForOne: !gbpfIsToken0, amountSpecified: -int256(60e18), sqrtPriceLimitX96: 0});
        v4Router.swap(hookKey, mintParams, address(this));
        uint256 gbpfHeld = IERC20Like(GBPF).balanceOf(address(this));

        int24 oracleTick = _oracleTick();
        _v3Swap(true, int256(gbpfHeld), oracleTick - 200);

        // No flush. Redeem inside rebalance will fail; band must still come back.
        buffer.rebalance();
        assertGt(buffer.positionTokenId(), 0, "position stranded after failed hook swap");
        assertLe(_absDiff(_spotTick(), _oracleTick()), 1, "spot not repegged despite failed hook swap");
    }

    // ============================================================
    // Oracle pause → pull all liquidity
    // ============================================================

    function test_oracle_pause_pulls_all_liquidity() public {
        buffer.rebalance();
        assertGt(uint256(pool.liquidity()), 0);

        // Chainlink staleness (26h) → oracle unhealthy. Absolute timestamp per the repo's
        // via_ir/vm.warp convention.
        vm.warp(block.timestamp + 27 hours);

        buffer.rebalance();
        assertEq(buffer.positionTokenId(), 0, "position not exited on pause");
        assertEq(uint256(pool.liquidity()), 0, "pool still has liquidity during oracle pause");
        // Inventory is safe in the vault.
        assertGt(
            IERC20Like(GBPF).balanceOf(address(buffer)) + IERC20Like(USDS).balanceOf(address(buffer)),
            0,
            "inventory vanished"
        );
    }

    // ============================================================
    // Owner controls
    // ============================================================

    function test_owner_can_exit_and_withdraw_all() public {
        buffer.rebalance();
        buffer.exitAndWithdrawAll(address(0xBEEF));
        assertEq(buffer.positionTokenId(), 0);
        assertGt(
            IERC20Like(GBPF).balanceOf(address(0xBEEF)) + IERC20Like(USDS).balanceOf(address(0xBEEF)),
            0,
            "owner received nothing"
        );
        assertEq(IERC20Like(USDS).balanceOf(address(buffer)), 0);
    }

    function test_non_owner_cannot_withdraw() public {
        buffer.rebalance();
        vm.prank(address(0xBAD));
        vm.expectRevert(BufferVault.NotOwner.selector);
        buffer.exitAndWithdrawAll(address(0xBAD));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _giveUsds(address to, uint256 amount) internal {
        require(IERC20Like(USDS).balanceOf(USDS_WHALE) >= amount, "whale short on USDS");
        vm.prank(USDS_WHALE);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS).transfer(to, amount);
    }

    /// @dev Direct V3 swap as a trader. zeroForOne=true sells token0. Exact input (positive),
    ///      bounded by a tick limit so empty-book slides land at a sane price.
    function _v3Swap(bool zeroForOne, int256 amountIn, int24 limitTick) internal {
        pool.swap(address(this), zeroForOne, amountIn, TickMath.getSqrtPriceAtTick(limitTick), "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "callback: not pool");
        address token0 = gbpfIsToken0 ? GBPF : USDS;
        address token1 = gbpfIsToken0 ? USDS : GBPF;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (amount0Delta > 0) IERC20Like(token0).transfer(msg.sender, uint256(amount0Delta));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        if (amount1Delta > 0) IERC20Like(token1).transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Uses update() — the same path BufferVault and the hook price with — NOT preview():
    ///      the live OracleAdapter's preview() has a known TWAP-amplification bug with sparse
    ///      un-ingested observations (see test/OracleAdapterPreviewRegression.t.sol). Mutates
    ///      fork state (ingests), which is fine in tests and matches what rebalance() sees.
    function _oracleSqrtX96() internal returns (uint160) {
        (uint256 twapWad, bool healthy,) = OracleAdapter(ORACLE).update();
        require(healthy, "oracle unhealthy at fork block");
        uint256 priceWad = gbpfIsToken0 ? twapWad : FixedPointMathLib.mulDiv(1e18, 1e18, twapWad);
        return uint160((FixedPointMathLib.sqrt(priceWad) << 96) / 1e9);
    }

    function _oracleTick() internal returns (int24) {
        return TickMath.getTickAtSqrtPrice(_oracleSqrtX96());
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function _gbpfTotalSupply() internal view returns (uint256) {
        (bool ok, bytes memory ret) = GBPF.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "totalSupply failed");
        return abi.decode(ret, (uint256));
    }

    function _absDiff(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a - b : b - a;
    }
}
