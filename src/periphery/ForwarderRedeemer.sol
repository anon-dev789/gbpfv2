// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPSM3} from "../interfaces/IPSM3.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3.sol";
import {Forwarder} from "./Forwarder.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IWETH {
    function withdraw(uint256) external;
}

interface IVaultFlush {
    function flush() external;
}

/// @title ForwarderRedeemer
/// @notice The mirror of ForwarderMinter: a user sends GBPF to their own deterministic deposit
///         address (plain transfer), and a permissionless runner sweeps any set of users and
///         redeems them to USDS pro-rata through the V4 hook in one transaction. Runner reimbursed
///         in ETH from a self-funding gas tank. Attribution is trustless via `CREATE2(this, user)`.
///         See BATCHMINTER_DESIGN.md ("Forwarder model").
///
///         PERIPHERY, NOT CORE. Owner for tuning + rescue only; cannot touch user funds (at
///         forwarder addresses) or escrowed `claimable` USDS.
contract ForwarderRedeemer is IUnlockCallback, IUniswapV3SwapCallback {
    using SafeTransferLib for address;

    // ============================================================================================
    // Immutable wiring
    // ============================================================================================

    address public immutable OWNER;
    IPoolManager public immutable POOL_MANAGER;
    address public immutable HOOK;
    IVaultFlush public immutable VAULT;
    address public immutable GBPF;
    address public immutable USDS;

    IPSM3 public immutable PSM3;
    address public immutable USDC;
    address public immutable WETH;
    IUniswapV3Pool public immutable USDC_WETH_POOL;

    bool public immutable GBPF_IS_TOKEN0;
    bool public immutable USDC_IS_TOKEN0;

    bytes32 public immutable FORWARDER_INIT_HASH;

    // ============================================================================================
    // Constants / params
    // ============================================================================================

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_FEE_USDS = 5e18;
    uint256 internal constant MAX_FIXED_FEE_USDS = 20e18;
    uint256 internal constant MAX_BONUS_BPS = 10_000;
    uint256 internal constant MAX_MAX_BATCH = 500;
    uint256 internal constant GAS_OVERHEAD = 50_000;

    uint256 public feeUsds = 0.05e18;
    uint256 public fixedFeeUsds = 0.1e18;
    uint256 public bonusBps = 2_000;
    uint256 public maxBatch = 150;

    // ============================================================================================
    // State
    // ============================================================================================

    /// @dev USDS escrowed because a direct push to a user reverted. Pull with claim().
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    uint256 private _locked = 1;

    // ============================================================================================
    // Events / errors
    // ============================================================================================

    event Swept(address indexed user, uint256 gbpfIn);
    event BatchExecuted(
        address indexed runner,
        uint256 userCount,
        uint256 gbpfRedeemed,
        uint256 usdsOut,
        uint256 feeCollected,
        uint256 runnerPayoutWei
    );
    event Refunded(address indexed user, uint256 gbpfReturned);
    event PushFailedEscrowed(address indexed user, uint256 usdsAmount);
    event Claimed(address indexed user, uint256 usdsAmount);
    event FeeSwappedToEth(uint256 usdsIn, uint256 ethOut);
    event FeeSwapFailed(bytes reason);
    event ParamsUpdated(uint256 feeUsds, uint256 fixedFeeUsds, uint256 bonusBps, uint256 maxBatch);
    event TankFunded(address indexed from, uint256 amount);
    event OwnerWithdrawal(address indexed token, uint256 amount, address to);

    error NotOwner();
    error NotPoolManager();
    error NotV3Pool();
    error NotSelf();
    error Reentrancy();
    error NothingToDo();
    error BatchTooLarge();
    error SlippageOrPause();
    error ParamTooHigh();
    error EthSendFailed();
    error ForwarderAddrMismatch();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(
        address owner_,
        address poolManager_,
        address hook_,
        address vault_,
        address gbpf_,
        address usds_,
        address psm3_,
        address usdc_,
        address weth_,
        address usdcWethPool_
    ) {
        OWNER = owner_;
        POOL_MANAGER = IPoolManager(poolManager_);
        HOOK = hook_;
        VAULT = IVaultFlush(vault_);
        GBPF = gbpf_;
        USDS = usds_;
        PSM3 = IPSM3(psm3_);
        USDC = usdc_;
        WETH = weth_;
        USDC_WETH_POOL = IUniswapV3Pool(usdcWethPool_);

        GBPF_IS_TOKEN0 = gbpf_ < usds_;
        USDC_IS_TOKEN0 = usdc_ < weth_;
        FORWARDER_INIT_HASH = keccak256(type(Forwarder).creationCode);

        usds_.safeApprove(psm3_, type(uint256).max);
    }

    /// @notice The token a Forwarder sweeps to this factory (GBPF). Read by Forwarder on deploy.
    function depositToken() external view returns (address) {
        return GBPF;
    }

    // ============================================================================================
    // Deposit addresses
    // ============================================================================================

    /// @notice The deterministic GBPF deposit address for `user` — send GBPF here (plain transfer).
    function depositAddressOf(address user) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(user), FORWARDER_INIT_HASH))))
        );
    }

    function _salt(address user) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    function _sweep(address user) internal returns (uint256 swept) {
        address f = depositAddressOf(user);
        if (IERC20Like(GBPF).balanceOf(f) == 0) return 0;
        uint256 before = IERC20Like(GBPF).balanceOf(address(this));
        if (f.code.length == 0) {
            Forwarder created = new Forwarder{salt: _salt(user)}();
            if (address(created) != f) revert ForwarderAddrMismatch();
        } else {
            Forwarder(f).flush();
        }
        swept = IERC20Like(GBPF).balanceOf(address(this)) - before;
    }

    // ============================================================================================
    // Sweep + execute
    // ============================================================================================

    /// @notice Permissionless. Sweeps each user's GBPF, redeems the lot through the hook, sends
    ///         each user their pro-rata USDS (net of fee), tops up the tank, and pays the runner.
    /// @param  users      Candidate depositor wallets (off-chain discovered). Empties/dups no-op.
    /// @param  minUsdsOut Abort if the hook would return less total USDS than this.
    function sweepAndExecute(address[] calldata users, uint256 minUsdsOut) external nonReentrant {
        uint256 gasStart = gasleft();

        uint256 len = users.length;
        if (len > maxBatch) revert BatchTooLarge();

        // 1. Sweep every user's GBPF into this contract; record amounts in memory.
        uint256[] memory amounts = new uint256[](len);
        uint256 count;
        uint256 totalGbpf;
        for (uint256 i = 0; i < len; ++i) {
            uint256 swept = _sweep(users[i]);
            amounts[i] = swept;
            if (swept > 0) {
                count += 1;
                totalGbpf += swept;
                emit Swept(users[i], swept);
            }
        }
        if (totalGbpf == 0) revert NothingToDo();

        // 2. Realise vault backing so the redeem is funded (no-op revert when idle is ignored).
        try VAULT.flush() {} catch {}

        // 3. Redeem all swept GBPF → USDS through the hook.
        uint256 usdsBefore = IERC20Like(USDS).balanceOf(address(this));
        POOL_MANAGER.unlock(abi.encode(totalGbpf));
        uint256 usdsOut = IERC20Like(USDS).balanceOf(address(this)) - usdsBefore;
        if (usdsOut < minUsdsOut || usdsOut == 0) revert SlippageOrPause();

        // 4. Distribute USDS pro-rata; the fee comes out of each user's proceeds (single pass).
        uint256 perHead = feeUsds + fixedFeeUsds / count;
        uint256 totalFee;
        for (uint256 i = 0; i < len; ++i) {
            uint256 a = amounts[i];
            if (a == 0) continue;
            uint256 gross = FixedPointMathLib.mulDiv(usdsOut, a, totalGbpf);
            uint256 fee = gross < perHead ? gross : perHead;
            totalFee += fee;
            uint256 net = gross - fee;
            if (net > 0) _pushOrEscrow(users[i], net);
        }

        // 5. Top up the tank from fees (best-effort), then reimburse the runner.
        if (totalFee > 0) {
            try this.swapFeeToEth(totalFee) {}
            catch (bytes memory reason) {
                emit FeeSwapFailed(reason);
            }
        }
        uint256 gasUsed = gasStart - gasleft() + GAS_OVERHEAD;
        uint256 reward = gasUsed * block.basefee * (BPS + bonusBps) / BPS;
        uint256 payout = reward < address(this).balance ? reward : address(this).balance;
        if (payout > 0) {
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert EthSendFailed();
        }

        emit BatchExecuted(msg.sender, count, totalGbpf, usdsOut, totalFee, payout);
    }

    /// @notice Permissionless escape hatch: sweep `user`'s GBPF and return it straight to them
    ///         (no swap, no fee). Can only return funds to the address that owns them.
    function refund(address user) external nonReentrant {
        uint256 swept = _sweep(user);
        if (swept == 0) revert NothingToDo();
        GBPF.safeTransfer(user, swept);
        emit Refunded(user, swept);
    }

    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToDo();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        USDS.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _pushOrEscrow(address d, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            USDS.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), d, amount));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        claimable[d] += amount;
        totalClaimable += amount;
        emit PushFailedEscrowed(d, amount);
    }

    // ============================================================================================
    // V4 hook swap (GBPF → USDS)
    // ============================================================================================

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 gbpfIn = abi.decode(data, (uint256));

        bool zeroForOne = GBPF_IS_TOKEN0; // redeem runs zeroForOne when GBPF is currency0
        PoolKey memory key = _hookPoolKey();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(gbpfIn);
        BalanceDelta delta = POOL_MANAGER.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}), ""
        );
        _settleLeg(key.currency0, delta.amount0());
        _settleLeg(key.currency1, delta.amount1());
        return "";
    }

    function _settleLeg(Currency currency, int128 amount) internal {
        if (amount == 0) return;
        if (amount < 0) {
            uint256 value = uint256(uint128(-amount));
            POOL_MANAGER.sync(currency);
            Currency.unwrap(currency).safeTransfer(address(POOL_MANAGER), value);
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _hookPoolKey() internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) =
            GBPF_IS_TOKEN0 ? (Currency.wrap(GBPF), Currency.wrap(USDS)) : (Currency.wrap(USDS), Currency.wrap(GBPF));
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(HOOK)});
    }

    // ============================================================================================
    // Fee → ETH
    // ============================================================================================

    function swapFeeToEth(uint256 usdsAmount) external {
        if (msg.sender != address(this)) revert NotSelf();

        uint256 minUsdc = PSM3.previewSwapExactIn(USDS, USDC, usdsAmount);
        uint256 usdcOut = PSM3.swapExactIn(USDS, USDC, usdsAmount, minUsdc, address(this), 0);

        uint256 wethBefore = IERC20Like(WETH).balanceOf(address(this));
        bool zeroForOne = USDC_IS_TOKEN0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        USDC_WETH_POOL.swap(address(this), zeroForOne, int256(usdcOut), limit, "");
        uint256 wethOut = IERC20Like(WETH).balanceOf(address(this)) - wethBefore;

        IWETH(WETH).withdraw(wethOut);
        emit FeeSwappedToEth(usdsAmount, wethOut);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(USDC_WETH_POOL)) revert NotV3Pool();
        if (amount0Delta > 0) (USDC_IS_TOKEN0 ? USDC : WETH).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) (USDC_IS_TOKEN0 ? WETH : USDC).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    // ============================================================================================
    // Owner
    // ============================================================================================

    function setParams(uint256 feeUsds_, uint256 fixedFeeUsds_, uint256 bonusBps_, uint256 maxBatch_)
        external
        onlyOwner
    {
        if (feeUsds_ > MAX_FEE_USDS || fixedFeeUsds_ > MAX_FIXED_FEE_USDS || bonusBps_ > MAX_BONUS_BPS) {
            revert ParamTooHigh();
        }
        if (maxBatch_ == 0 || maxBatch_ > MAX_MAX_BATCH) revert ParamTooHigh();
        feeUsds = feeUsds_;
        fixedFeeUsds = fixedFeeUsds_;
        bonusBps = bonusBps_;
        maxBatch = maxBatch_;
        emit ParamsUpdated(feeUsds_, fixedFeeUsds_, bonusBps_, maxBatch_);
    }

    function fundTank() external payable {
        emit TankFunded(msg.sender, msg.value);
    }

    function withdrawEth(uint256 amount, address to) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit OwnerWithdrawal(address(0), amount, to);
    }

    /// @notice Rescue strays. Escrowed (claimable) USDS can never be swept out. No GBPF reserve
    ///         is needed: user GBPF lives at forwarder addresses, not here, between batches.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == USDS) {
            require(amount <= IERC20Like(USDS).balanceOf(address(this)) - totalClaimable, "USDS reserved for escrow");
        }
        token.safeTransfer(to, amount);
        emit OwnerWithdrawal(token, amount, to);
    }

    function gasTank() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
