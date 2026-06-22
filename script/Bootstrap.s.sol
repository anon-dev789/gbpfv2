// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// @dev Minimal swap router implementing the V4 unlock callback. Identical in behaviour to the
///      one proven in test/fork/Hook.fork.t.sol: the caller approves this router for the input
///      token, calls swap(), the PoolManager calls back through unlockCallback, the swap runs,
///      and the resulting deltas are settled (owe PM → sync+transferFrom+settle; PM owes → take).
contract MinimalRouter is IUnlockCallback {
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

    /// @dev Delta from the SWAPPER's perspective:
    ///        delta < 0 → swapper owes PM (sync + transferFrom + settle)
    ///        delta > 0 → PM owes swapper (take)
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
            uint256 value = uint256(uint128(amount));
            POOL_MANAGER.take(currency, recipient, value);
        }
    }
}

/// @title Bootstrap
/// @notice Step 2 of the GBPF deploy: the seed-and-burn bootstrap. Run AFTER Deploy.s.sol has
///         deployed + initialized the four contracts on Base.
///
///         Performs the three manual post-deploy steps the deploy script only printed:
///           1. PoolManager.initialize() the canonical (USDS, GBPF) pool.
///           2. Seed swap: exact-input mint of 1 USDS → ~0.8 GBPF (to the deployer).
///           3. Burn: transfer all GBPF received to 0xdEaD.
///
///         After this completes, the protocol is fully bootstrapped and open for use.
///
///         Prerequisites:
///           - Deploy.s.sol already run; addresses below filled in from its output.
///           - The deployer (broadcast sender) holds >= 1 USDS on Base for the seed + ETH for gas.
///
///         Usage (simulate first — NO --broadcast):
///           forge script script/Bootstrap.s.sol:Bootstrap \
///             --rpc-url https://mainnet.base.org \
///             --sender 0xYourDeployerAddress
///
///         Then broadcast:
///           forge script script/Bootstrap.s.sol:Bootstrap \
///             --rpc-url https://mainnet.base.org --broadcast --slow \
///             --account deployer --sender 0xYourDeployerAddress
contract Bootstrap is Script {
    // ============================================================================================
    // Deployed addresses — from Deploy.s.sol output (Base 8453, commit 60d3895, post-audit
    // redeploy). See DEPLOYMENT.md. (Supersedes the abandoned 53980bf deploy.)
    // ============================================================================================

    // Core addresses (GBPF, HOOK) are read from env at runtime — set them to the freshly deployed
    // core (GBPF_ADDR, HOOK_ADDR). No defaults: a missing env var reverts rather than targeting a
    // stale core.

    // Base mainnet infra (matches Deploy.s.sol).
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// Seed size, in USDS (18 decimals). Matches Deploy.s.sol SEED_USDS.
    uint256 internal constant SEED_USDS = 1e18;

    /// Q96-encoded 1.0 (= 2^96). The hook ignores the pool's own price (oracle-driven), but V4
    /// requires a valid initial sqrtPriceX96 within bounds. This is the value the fork test uses.
    uint160 internal constant SQRT_PRICE_X96_ONE = 79228162514264337593543950336;

    function run() external {
        address GBPF = vm.envOr("GBPF_ADDR", address(0));
        address HOOK = vm.envOr("HOOK_ADDR", address(0));
        require(GBPF != address(0) && GBPF.code.length > 0, "set GBPF_ADDR env to the new GBPF");
        require(HOOK != address(0) && HOOK.code.length > 0, "set HOOK_ADDR env to the new Hook");

        bool usdsIsToken0 = USDS_TOKEN < GBPF;

        // Canonical PoolKey — must hash-equal the hook's immutable POOL_KEY_HASH:
        //   currencies sorted by address, fee = 0, tickSpacing = 1, hooks = HOOK.
        PoolKey memory key = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(USDS_TOKEN) : Currency.wrap(GBPF),
            currency1: usdsIsToken0 ? Currency.wrap(GBPF) : Currency.wrap(USDS_TOKEN),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(HOOK)
        });

        address deployer = msg.sender;

        // Pre-flight: deployer must hold the seed.
        uint256 deployerUsds = IERC20Like(USDS_TOKEN).balanceOf(deployer);
        require(deployerUsds >= SEED_USDS, "deployer USDS balance < SEED_USDS");

        vm.startBroadcast();

        // ---------------------------------------------------------------------------------------
        // Step 1: initialise the V4 pool. Permissionless; anyone can call. We tolerate an
        // already-initialised pool (e.g. a griefer front-ran the canonical-key init, or a partial
        // earlier run): the pool's starting price is irrelevant because the hook fully replaces V4
        // pool math with its own oracle pricing, so any prior init with the canonical key is
        // harmless and we simply proceed to the seed swap rather than aborting the whole bootstrap.
        // ---------------------------------------------------------------------------------------
        try IPoolManager(V4_POOL_MANAGER).initialize(key, SQRT_PRICE_X96_ONE) {
            console2.log("Pool initialised.");
        } catch {
            console2.log("Pool already initialised (or init reverted); continuing to seed swap.");
        }

        // ---------------------------------------------------------------------------------------
        // Step 2: seed swap. Deploy the router, approve it, mint exactly SEED_USDS of GBPF to
        // the deployer. mint direction is zeroForOne == usdsIsToken0; exact-input is a negative
        // amountSpecified.
        // ---------------------------------------------------------------------------------------
        MinimalRouter router = new MinimalRouter(V4_POOL_MANAGER);
        console2.log("Router deployed at", address(router));

        uint256 gbpfBefore = IERC20Like(GBPF).balanceOf(deployer);

        IERC20Like(USDS_TOKEN).approve(address(router), SEED_USDS);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 seedSpecified = -int256(SEED_USDS); // SEED_USDS = 1e18 ≪ int256 max; cannot wrap.
        SwapParams memory params =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: seedSpecified, sqrtPriceLimitX96: 0});
        router.swap(key, params, deployer);

        uint256 gbpfReceived = IERC20Like(GBPF).balanceOf(deployer) - gbpfBefore;
        require(gbpfReceived > 0, "seed swap produced no GBPF");
        console2.log("Seed swap done. GBPF received (wei):", gbpfReceived);

        // ---------------------------------------------------------------------------------------
        // Step 3: burn the seed. Transfer ALL GBPF the deployer now holds to 0xdEaD. We sweep the
        // full balance (not just gbpfReceived) so the deployer ends with zero GBPF.
        // ---------------------------------------------------------------------------------------
        uint256 gbpfToBurn = IERC20Like(GBPF).balanceOf(deployer);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(GBPF).transfer(BURN_ADDRESS, gbpfToBurn);
        console2.log("Seed burned (wei):", gbpfToBurn);

        vm.stopBroadcast();

        require(IERC20Like(GBPF).balanceOf(deployer) == 0, "deployer still holds GBPF after burn");

        console2.log("=== BOOTSTRAP COMPLETE ===");
        console2.log("GBPF total supply (wei):", IERC20Like(GBPF).totalSupply());
        console2.log("Protocol is now open for use.");
    }
}
