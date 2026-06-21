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

/// @title BatchRedeemer
/// @notice The mirror of BatchMinter: pools many users' GBPF into a single batched redeem through
///         the V4 hook, returns USDS pro-rata to each depositor in one transaction, and pays the
///         permissionless "runner" who triggers the batch out of an ETH gas tank kept topped up
///         by a per-depositor + shared-fixed fee taken from the USDS proceeds (USDS → USDC →
///         WETH → ETH).
///
///         See BATCHMINTER_DESIGN.md for the shared design; this contract is the GBPF→USDS leg.
///
///         PERIPHERY, NOT CORE. Has an owner for tuning and rescue; market integrity never
///         depends on the owner. Redeems at exactly the hook's oracle price. Custodies user GBPF
///         only transiently (deposit → next batch) and the ETH tank; never holds user USDS
///         except the rare push-failure escrow.
contract BatchRedeemer is IUnlockCallback, IUniswapV3SwapCallback {
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

    // ============================================================================================
    // Constants
    // ============================================================================================

    uint256 internal constant BPS = 10_000;

    uint256 internal constant MAX_FEE_USDS = 5e18; // 5 USDS / depositor (marginal)
    uint256 internal constant MAX_FIXED_FEE_USDS = 20e18; // 20 USDS / batch (split across depositors)
    uint256 internal constant MAX_BONUS_BPS = 10_000; // 100%
    uint256 internal constant MAX_MAX_DEPOSITORS = 500;
    /// @dev Floor on a single GBPF deposit, so dust deposits whose USDS proceeds wouldn't cover
    ///      the fee can't queue. Owner-tunable; keep ≳ (feeUsds + fixedFeeUsds) / GBPF price.
    uint256 internal constant MAX_MIN_GBPF_DEPOSIT = 1_000e18;

    uint256 internal constant GAS_OVERHEAD = 50_000;

    // ============================================================================================
    // Owner-tunable parameters
    // ============================================================================================

    uint256 public feeUsds = 0.05e18; // per-depositor marginal fee
    uint256 public fixedFeeUsds = 0.1e18; // per-batch fixed fee, split /n
    uint256 public bonusBps = 2_000;
    uint256 public maxDepositors = 150;
    uint256 public minGbpfDeposit = 0.2e18; // dust floor (~0.25 USDS at parity)

    // ============================================================================================
    // Queue state
    // ============================================================================================

    mapping(address => uint256) public pendingGbpf;
    mapping(address => uint256) private depositorIndexPlus1;
    address[] public depositors;
    uint256 public totalQueued;

    /// @dev USDS escrowed because a direct push to a depositor reverted. Pull with claim().
    mapping(address => uint256) public claimable;
    /// @dev Sum of all `claimable` USDS — reserved against `rescueToken` so the owner can never
    ///      sweep escrowed user funds.
    uint256 public totalClaimable;

    uint256 private _locked = 1;

    // ============================================================================================
    // Events / errors
    // ============================================================================================

    event Deposited(address indexed depositor, uint256 amount, uint256 totalQueued);
    event DepositWithdrawn(address indexed depositor, uint256 amount);
    event BatchExecuted(
        address indexed runner,
        uint256 depositorCount,
        uint256 gbpfRedeemed,
        uint256 usdsOut,
        uint256 feeCollected,
        uint256 runnerPayoutWei
    );
    event PushFailedEscrowed(address indexed depositor, uint256 usdsAmount);
    event Claimed(address indexed depositor, uint256 usdsAmount);
    event FeeSwappedToEth(uint256 usdsIn, uint256 ethOut);
    event FeeSwapFailed(bytes reason);
    event ParamsUpdated(
        uint256 feeUsds, uint256 fixedFeeUsds, uint256 bonusBps, uint256 maxDepositors, uint256 minGbpfDeposit
    );
    event TankFunded(address indexed from, uint256 amount);
    event OwnerWithdrawal(address indexed token, uint256 amount, address to);

    error NotOwner();
    error NotPoolManager();
    error NotV3Pool();
    error NotSelf();
    error Reentrancy();
    error NothingToDo();
    error BatchFull();
    error BelowMinDeposit();
    error ZeroAmount();
    error NoDeposit();
    error SlippageOrPause();
    error ParamTooHigh();
    error EthSendFailed();

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

        // PSM3 pulls USDS from this contract on every fee swap. Approve once.
        usds_.safeApprove(psm3_, type(uint256).max);
    }

    // ============================================================================================
    // Depositors
    // ============================================================================================

    /// @notice Queue `amount` GBPF for the next batch. Requires prior GBPF approval to this
    ///         contract. Re-depositing adds to your existing queued amount.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        if (pendingGbpf[msg.sender] == 0) {
            if (depositors.length >= maxDepositors) revert BatchFull();
            depositors.push(msg.sender);
            depositorIndexPlus1[msg.sender] = depositors.length; // 1-based
        }
        pendingGbpf[msg.sender] += amount;
        // Dust floor: the fee is taken from USDS proceeds, so a deposit must be large enough that
        // its proceeds plausibly exceed the fee. Owner sizes minGbpfDeposit to the price band.
        if (pendingGbpf[msg.sender] < minGbpfDeposit) revert BelowMinDeposit();
        totalQueued += amount;

        GBPF.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, totalQueued);
    }

    /// @notice Reclaim your full queued GBPF before a batch runs.
    function withdrawDeposit() external nonReentrant {
        uint256 amount = pendingGbpf[msg.sender];
        if (amount == 0) revert NoDeposit();

        _removeDepositor(msg.sender);
        totalQueued -= amount;

        GBPF.safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(msg.sender, amount);
    }

    /// @notice Pull USDS that was escrowed for you because a direct push failed.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NoDeposit();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        USDS.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ============================================================================================
    // Batch execution — the runner's entry point
    // ============================================================================================

    /// @notice Permissionless. Redeems the whole queue's GBPF into USDS through the hook, sends
    ///         each depositor their pro-rata USDS (net of fee), tops up the ETH tank from the
    ///         fees, and pays the caller (the runner) gas + bonus from the tank.
    /// @param  minUsdsOut Abort if the hook would return less total USDS than this (slippage /
    ///                    oracle drift guard). Pass 0 to accept any non-zero output.
    function executeBatch(uint256 minUsdsOut) external nonReentrant {
        uint256 gasStart = gasleft();

        uint256 queued = totalQueued; // GBPF
        if (queued == 0) revert NothingToDo();

        uint256 n = depositors.length; // ≥ 1 whenever queued > 0
        uint256 perHead = feeUsds + fixedFeeUsds / n;

        // Realise the vault's pending claims into sUSDS backing so the redeem is funded. flush()
        // reverts NothingToFlush when idle — that's fine, ignore it.
        try VAULT.flush() {} catch {}

        // Redeem all queued GBPF → USDS through the hook.
        uint256 usdsBefore = IERC20Like(USDS).balanceOf(address(this));
        POOL_MANAGER.unlock(abi.encode(queued));
        uint256 usdsOut = IERC20Like(USDS).balanceOf(address(this)) - usdsBefore;
        if (usdsOut < minUsdsOut || usdsOut == 0) revert SlippageOrPause();

        // Distribute USDS pro-rata, deduct each depositor's fee from their proceeds, reset queue.
        // Single pass: the fee comes out of the output, so (unlike the minter) we don't need it
        // before the swap.
        uint256 totalFee;
        for (uint256 i = 0; i < n; ++i) {
            address d = depositors[i];
            uint256 gross = FixedPointMathLib.mulDiv(usdsOut, pendingGbpf[d], queued);
            uint256 fee = gross < perHead ? gross : perHead;
            totalFee += fee;
            pendingGbpf[d] = 0;
            depositorIndexPlus1[d] = 0;
            uint256 net = gross - fee;
            if (net > 0) _pushOrEscrow(d, net);
        }
        delete depositors;
        totalQueued = 0;

        // Top up the ETH tank from the collected fees. Best-effort.
        if (totalFee > 0) {
            try this.swapFeeToEth(totalFee) {}
            catch (bytes memory reason) {
                emit FeeSwapFailed(reason);
            }
        }

        // Reimburse the runner gas + bonus, capped by the tank. Last action; guard still held.
        uint256 gasUsed = gasStart - gasleft() + GAS_OVERHEAD;
        uint256 reward = gasUsed * block.basefee * (BPS + bonusBps) / BPS;
        uint256 payout = reward < address(this).balance ? reward : address(this).balance;
        if (payout > 0) {
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert EthSendFailed();
        }

        emit BatchExecuted(msg.sender, n, queued, usdsOut, totalFee, payout);
    }

    /// @dev Push `amount` USDS to `d`; on any failure escrow it as claimable instead of reverting
    ///      the whole batch.
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

    /// @dev V4 unlock callback: exact-input GBPF → USDS against the hook pool, settle both legs.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 gbpfIn = abi.decode(data, (uint256));

        // redeem (GBPF → USDS) runs zeroForOne when GBPF is currency0.
        bool zeroForOne = GBPF_IS_TOKEN0;
        PoolKey memory key = _hookPoolKey();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(gbpfIn); // exact input; queue total ≪ int256 max
        BalanceDelta delta = POOL_MANAGER.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}), ""
        );

        _settleLeg(key.currency0, delta.amount0());
        _settleLeg(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Delta from this contract's (the swapper's) perspective:
    ///        negative → we owe the PoolManager (sync + transfer + settle)  [the GBPF leg]
    ///        positive → the PoolManager owes us (take)                     [the USDS leg]
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
    // Fee → ETH (USDS → USDC → WETH → ETH)
    // ============================================================================================

    /// @notice Convert `usdsAmount` of collected fee USDS to native ETH in the tank. Self-call
    ///         only — invoked by executeBatch through try/catch so a route failure can't block
    ///         user redeems.
    function swapFeeToEth(uint256 usdsAmount) external {
        if (msg.sender != address(this)) revert NotSelf();

        uint256 minUsdc = PSM3.previewSwapExactIn(USDS, USDC, usdsAmount);
        uint256 usdcOut = PSM3.swapExactIn(USDS, USDC, usdsAmount, minUsdc, address(this), 0);

        uint256 wethBefore = IERC20Like(WETH).balanceOf(address(this));
        bool zeroForOne = USDC_IS_TOKEN0; // selling USDC
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        USDC_WETH_POOL.swap(address(this), zeroForOne, int256(usdcOut), limit, "");
        uint256 wethOut = IERC20Like(WETH).balanceOf(address(this)) - wethBefore;

        IWETH(WETH).withdraw(wethOut);
        emit FeeSwappedToEth(usdsAmount, wethOut);
    }

    /// @dev V3 swap callback: pay the USDC the pool is owed for the USDC → WETH swap.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(USDC_WETH_POOL)) revert NotV3Pool();
        if (amount0Delta > 0) {
            (USDC_IS_TOKEN0 ? USDC : WETH).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            (USDC_IS_TOKEN0 ? WETH : USDC).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    // ============================================================================================
    // Owner — tuning, tank funding, rescue
    // ============================================================================================

    function setParams(
        uint256 feeUsds_,
        uint256 fixedFeeUsds_,
        uint256 bonusBps_,
        uint256 maxDepositors_,
        uint256 minGbpfDeposit_
    ) external onlyOwner {
        if (feeUsds_ > MAX_FEE_USDS || fixedFeeUsds_ > MAX_FIXED_FEE_USDS || bonusBps_ > MAX_BONUS_BPS) {
            revert ParamTooHigh();
        }
        if (maxDepositors_ == 0 || maxDepositors_ > MAX_MAX_DEPOSITORS) revert ParamTooHigh();
        if (minGbpfDeposit_ == 0 || minGbpfDeposit_ > MAX_MIN_GBPF_DEPOSIT) revert ParamTooHigh();
        feeUsds = feeUsds_;
        fixedFeeUsds = fixedFeeUsds_;
        bonusBps = bonusBps_;
        maxDepositors = maxDepositors_;
        minGbpfDeposit = minGbpfDeposit_;
        emit ParamsUpdated(feeUsds_, fixedFeeUsds_, bonusBps_, maxDepositors_, minGbpfDeposit_);
    }

    /// @notice Seed the ETH gas tank directly.
    function fundTank() external payable {
        emit TankFunded(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH from the tank. Cannot touch queued GBPF or escrowed USDS.
    function withdrawEth(uint256 amount, address to) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit OwnerWithdrawal(address(0), amount, to);
    }

    /// @notice Rescue stray tokens. Queued GBPF can never be swept out from under depositors.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == GBPF) {
            // Queued deposits are not strays.
            require(amount <= IERC20Like(GBPF).balanceOf(address(this)) - totalQueued, "GBPF reserved for queue");
        } else if (token == USDS) {
            // Escrowed (claimable) USDS is not a stray.
            require(amount <= IERC20Like(USDS).balanceOf(address(this)) - totalClaimable, "USDS reserved for escrow");
        }
        token.safeTransfer(to, amount);
        emit OwnerWithdrawal(token, amount, to);
    }

    // ============================================================================================
    // Internals / views
    // ============================================================================================

    function _removeDepositor(address d) internal {
        uint256 idx = depositorIndexPlus1[d] - 1;
        uint256 lastIdx = depositors.length - 1;
        if (idx != lastIdx) {
            address last = depositors[lastIdx];
            depositors[idx] = last;
            depositorIndexPlus1[last] = idx + 1;
        }
        depositors.pop();
        pendingGbpf[d] = 0;
        depositorIndexPlus1[d] = 0;
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function gasTank() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
