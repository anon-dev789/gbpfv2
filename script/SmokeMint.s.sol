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
}

/// @dev Same minimal unlock-callback router proven in test/fork/Hook.fork.t.sol and used by
///      Bootstrap.s.sol. Approve it for the input token, call swap(), the PoolManager calls back,
///      the swap runs, and deltas are settled (owe PM -> sync+transferFrom+settle; PM owes -> take).
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

/// @title SmokeMint
/// @notice Smoke test: perform ONE real USDS -> GBPF mint through the live hook, from the
///         broadcasting wallet, to confirm a real user can mint. NOT a setup/activation step
///         (the pool is already live and has processed the seed swap) — purely a sanity check.
///
///         The GBPF minted lands in the caller's wallet and is kept (unlike the bootstrap, which
///         burns it). To unwind, redeem it back later.
///
///         Amount: set MINT_USDS (in whole USDS) in the env. Defaults to 1 USDS if unset.
///
///         Usage (simulate first — NO --broadcast):
///           MINT_USDS=1 forge script script/SmokeMint.s.sol:SmokeMint \
///             --rpc-url https://mainnet.base.org --sender 0xYourWallet
///
///         Broadcast:
///           MINT_USDS=1 forge script script/SmokeMint.s.sol:SmokeMint \
///             --rpc-url https://mainnet.base.org --broadcast --slow \
///             --account deployer --sender 0xYourWallet
contract SmokeMint is Script {
    // Live deploy (Base 8453, commit 60d3895). See DEPLOYMENT.md.
    address internal constant GBPF = 0x1817FD23ceF7Da47DF934fdc880d72e653786770;
    address internal constant HOOK = 0x5613c279E8Db9815DBD0CdFbd10515EAbD350088;

    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    function run() external {
        // Mint amount: MINT_USDS whole USDS (18 decimals). Default 1.
        uint256 mintWholeUsds = vm.envOr("MINT_USDS", uint256(1));
        uint256 mintUsds = mintWholeUsds * 1e18;

        address caller = msg.sender;
        bool usdsIsToken0 = USDS_TOKEN < GBPF; // false for this deploy (GBPF sorts first).

        PoolKey memory key = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(USDS_TOKEN) : Currency.wrap(GBPF),
            currency1: usdsIsToken0 ? Currency.wrap(GBPF) : Currency.wrap(USDS_TOKEN),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(HOOK)
        });

        uint256 usdsBefore = IERC20Like(USDS_TOKEN).balanceOf(caller);
        uint256 gbpfBefore = IERC20Like(GBPF).balanceOf(caller);
        require(usdsBefore >= mintUsds, "caller USDS balance < MINT_USDS");
        console2.log("Minting USDS (wei):", mintUsds);

        vm.startBroadcast();

        // Fresh router per run — stateless, holds no funds between calls.
        MinimalRouter router = new MinimalRouter(V4_POOL_MANAGER);

        IERC20Like(USDS_TOKEN).approve(address(router), mintUsds);

        // Mint = USDS -> GBPF. Direction zeroForOne == usdsIsToken0. Exact-input -> negative.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(mintUsds); // mintUsds is small; cannot wrap.
        SwapParams memory params =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
        router.swap(key, params, caller);

        vm.stopBroadcast();

        uint256 usdsSpent = usdsBefore - IERC20Like(USDS_TOKEN).balanceOf(caller);
        uint256 gbpfReceived = IERC20Like(GBPF).balanceOf(caller) - gbpfBefore;

        require(usdsSpent == mintUsds, "USDS spent != requested mint amount");
        require(gbpfReceived > 0, "no GBPF received");

        console2.log("=== SMOKE MINT OK ===");
        console2.log("USDS spent (wei):    ", usdsSpent);
        console2.log("GBPF received (wei): ", gbpfReceived);
        console2.log("Caller now holds GBPF (wei):", IERC20Like(GBPF).balanceOf(caller));
        console2.log("Note: a pending USDS claim now sits on the Vault until flush() runs.");
    }
}
