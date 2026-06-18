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

/// @title BatchMinter
/// @notice Gateway periphery: pools many users' USDS into a single batched mint through the V4
///         hook, returns GBPF pro-rata to each depositor in one transaction, and pays the
///         permissionless "runner" who triggers the batch out of an ETH gas tank that is kept
///         topped up by a flat per-depositor fee on each batch (USDS → USDC → WETH → ETH).
///
///         See BATCHMINTER_DESIGN.md for the full design.
///
///         PERIPHERY, NOT CORE. Not part of the immutable audited core. Has an owner for tuning
///         and rescue; market integrity never depends on the owner. The contract mints at
///         exactly the hook's oracle price — it changes no protocol pricing, backing, or
///         solvency. It custodies user USDS only transiently (deposit → next batch) and the ETH
///         tank; it never holds user GBPF except the rare push-failure escrow.
contract BatchMinter is IUnlockCallback, IUniswapV3SwapCallback {
    using SafeTransferLib for address;

    // ============================================================================================
    // Immutable wiring
    // ============================================================================================

    address public immutable OWNER;
    IPoolManager public immutable POOL_MANAGER;
    address public immutable HOOK;
    address public immutable GBPF;
    address public immutable USDS;

    IPSM3 public immutable PSM3;
    address public immutable USDC;
    address public immutable WETH;
    IUniswapV3Pool public immutable USDC_WETH_POOL;

    /// @dev True iff GBPF sorts below USDS — drives the hook pool's currency0/currency1 order.
    bool public immutable GBPF_IS_TOKEN0;
    /// @dev True iff USDC sorts below WETH — drives the V3 swap direction (zeroForOne).
    bool public immutable USDC_IS_TOKEN0;

    // ============================================================================================
    // Constants
    // ============================================================================================

    uint256 internal constant BPS = 10_000;

    /// @dev Hard caps on owner-tunable params (see setters). The owner can never charge more than
    ///      5 USDS per depositor + 20 USDS fixed per batch, nor pay a runner bonus above 100% of
    ///      basefee reimbursement.
    uint256 internal constant MAX_FEE_USDS = 5e18; // 5 USDS / depositor (marginal)
    uint256 internal constant MAX_FIXED_FEE_USDS = 20e18; // 20 USDS / batch (split across depositors)
    uint256 internal constant MAX_BONUS_BPS = 10_000; // 100%
    uint256 internal constant MAX_MAX_DEPOSITORS = 500;

    /// @dev Fixed gas not captured by the gasleft() delta: 21k base tx, calldata, the payout
    ///      call, and post-measurement bookkeeping. Deliberately modest so the contract never
    ///      over-reimburses; the bonus absorbs the slack.
    uint256 internal constant GAS_OVERHEAD = 50_000;

    // ============================================================================================
    // Owner-tunable parameters
    // ============================================================================================

    /// @dev The per-depositor MARGINAL fee, in USDS. Covers the gas each depositor adds to the
    ///      batch (one distribution transfer + storage writes) — constant regardless of deposit
    ///      size. Each depositor pays this.
    uint256 public feeUsds = 0.05e18; // 5 cents / depositor

    /// @dev The per-batch FIXED fee, in USDS, split evenly across the batch's depositors
    ///      (`fixedFeeUsds / n` each). Covers the gas paid once per batch no matter how many
    ///      depositors there are — the single hook swap + the USDS→ETH conversion + base tx. So
    ///      total fee = n × feeUsds + fixedFeeUsds, mirroring gas = marginal × n + fixed. A lone
    ///      depositor bears the whole fixed cost, which discourages uneconomic tiny batches.
    uint256 public fixedFeeUsds = 0.10e18; // ~one batch's fixed overhead at Base gas

    uint256 public bonusBps = 2_000; // +20% over basefee reimbursement
    uint256 public maxDepositors = 150;

    // ============================================================================================
    // Queue state
    // ============================================================================================

    mapping(address => uint256) public pendingUsds;
    mapping(address => uint256) private depositorIndexPlus1;
    address[] public depositors;
    uint256 public totalQueued;

    /// @dev GBPF escrowed because a direct push to a depositor reverted. Pull with claim().
    mapping(address => uint256) public claimable;
    /// @dev Sum of all `claimable` GBPF — reserved against `rescueToken` so the owner can never
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
        uint256 usdsSwapped,
        uint256 gbpfOut,
        uint256 feeCollected,
        uint256 runnerPayoutWei
    );
    event PushFailedEscrowed(address indexed depositor, uint256 gbpfAmount);
    event Claimed(address indexed depositor, uint256 gbpfAmount);
    event FeeSwappedToEth(uint256 usdsIn, uint256 ethOut);
    event FeeSwapFailed(bytes reason);
    event ParamsUpdated(uint256 feeUsds, uint256 fixedFeeUsds, uint256 bonusBps, uint256 maxDepositors);
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
        GBPF = gbpf_;
        USDS = usds_;
        PSM3 = IPSM3(psm3_);
        USDC = usdc_;
        WETH = weth_;
        USDC_WETH_POOL = IUniswapV3Pool(usdcWethPool_);

        GBPF_IS_TOKEN0 = gbpf_ < usds_;
        USDC_IS_TOKEN0 = usdc_ < weth_;

        // PSM3 pulls USDS from this contract via transferFrom on every fee swap. Approve once.
        usds_.safeApprove(psm3_, type(uint256).max);
    }

    // ============================================================================================
    // Depositors
    // ============================================================================================

    /// @notice Queue `amount` USDS for the next batch. Requires prior USDS approval to this
    ///         contract. Re-depositing adds to your existing queued amount.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        if (pendingUsds[msg.sender] == 0) {
            if (depositors.length >= maxDepositors) revert BatchFull();
            depositors.push(msg.sender);
            depositorIndexPlus1[msg.sender] = depositors.length; // 1-based
        }
        pendingUsds[msg.sender] += amount;
        // A deposit must cover its worst-case fee — being the lone depositor, who bears the whole
        // fixed fee (perHead = feeUsds + fixedFeeUsds/n is maximised at n = 1). Guarantees every
        // accepted deposit mints something even if no one else joins the batch.
        if (pendingUsds[msg.sender] < feeUsds + fixedFeeUsds) revert BelowMinDeposit();
        totalQueued += amount;

        USDS.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, totalQueued);
    }

    /// @notice Reclaim your full queued USDS before a batch runs.
    function withdrawDeposit() external nonReentrant {
        uint256 amount = pendingUsds[msg.sender];
        if (amount == 0) revert NoDeposit();

        _removeDepositor(msg.sender);
        totalQueued -= amount;

        USDS.safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(msg.sender, amount);
    }

    /// @notice Pull GBPF that was escrowed for you because a direct push failed.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NoDeposit();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        GBPF.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ============================================================================================
    // Batch execution — the runner's entry point
    // ============================================================================================

    /// @notice Permissionless. Mints the whole queue's USDS into GBPF through the hook, sends
    ///         each depositor their pro-rata GBPF, tops up the ETH tank from the flat fees, pays the
    ///         caller (the runner) gas + bonus from the tank.
    /// @param  minGbpfOut Abort if the hook would return less GBPF than this (slippage / oracle
    ///                    drift guard). Pass 0 to accept any non-zero output.
    function executeBatch(uint256 minGbpfOut) external nonReentrant {
        uint256 gasStart = gasleft();

        uint256 queued = totalQueued;
        if (queued == 0) revert NothingToDo();

        uint256 n = depositors.length; // ≥ 1 whenever queued > 0

        // Each depositor pays the marginal fee + an equal share of the batch's fixed fee.
        // total = n × feeUsds + fixedFeeUsds, mirroring gas = marginal × n + fixed.
        uint256 perHead = feeUsds + fixedFeeUsds / n;

        // 1. Sum the per-depositor fee (capped at each depositor's balance, so a fee raised after
        //    someone queued can never push their net below zero). The remainder is minted.
        uint256 totalFee;
        for (uint256 i = 0; i < n; ++i) {
            uint256 p = pendingUsds[depositors[i]];
            totalFee += p < perHead ? p : perHead;
        }
        uint256 swapUsds = queued - totalFee;
        if (swapUsds == 0) revert NothingToDo();

        // 2. Swap the net USDS → GBPF through the hook.
        uint256 gbpfBefore = IERC20Like(GBPF).balanceOf(address(this));
        POOL_MANAGER.unlock(abi.encode(swapUsds));
        uint256 gbpfOut = IERC20Like(GBPF).balanceOf(address(this)) - gbpfBefore;
        if (gbpfOut < minGbpfOut || gbpfOut == 0) revert SlippageOrPause();

        // 3. Distribute GBPF pro-rata to each depositor's NET (post-fee) contribution; reset queue.
        for (uint256 i = 0; i < n; ++i) {
            address d = depositors[i];
            uint256 p = pendingUsds[d];
            uint256 net = p - (p < perHead ? p : perHead);
            pendingUsds[d] = 0;
            depositorIndexPlus1[d] = 0;
            if (net > 0) {
                uint256 share = FixedPointMathLib.mulDiv(gbpfOut, net, swapUsds);
                if (share > 0) _pushOrEscrow(d, share);
            }
        }
        delete depositors;
        totalQueued = 0;

        // 4. Top up the ETH tank from the collected fees. Best-effort: a failed conversion must
        //    not block the mint — the fee USDS stays and rolls into a future top-up.
        if (totalFee > 0) {
            try this.swapFeeToEth(totalFee) {} catch (bytes memory reason) {
                emit FeeSwapFailed(reason);
            }
        }

        // 5. Reimburse the runner gas + bonus, capped by the tank. Last action; guard still held.
        uint256 gasUsed = gasStart - gasleft() + GAS_OVERHEAD;
        uint256 reward = gasUsed * block.basefee * (BPS + bonusBps) / BPS;
        uint256 payout = reward < address(this).balance ? reward : address(this).balance;
        if (payout > 0) {
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert EthSendFailed();
        }

        emit BatchExecuted(msg.sender, n, swapUsds, gbpfOut, totalFee, payout);
    }

    /// @dev Push `amount` GBPF to `d`; on any failure (reverting/!true recipient) escrow it as
    ///      claimable instead of reverting the whole batch. Keeps one bad depositor from
    ///      bricking everyone else's mint.
    function _pushOrEscrow(address d, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            GBPF.call(abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), d, amount));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        claimable[d] += amount;
        totalClaimable += amount;
        emit PushFailedEscrowed(d, amount);
    }

    // ============================================================================================
    // V4 hook swap (USDS → GBPF)
    // ============================================================================================

    /// @dev V4 unlock callback: exact-input USDS → GBPF against the hook pool, settle both legs.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 usdsIn = abi.decode(data, (uint256));

        // mint (USDS → GBPF) runs zeroForOne when USDS is currency0, i.e. when GBPF is NOT token0.
        bool zeroForOne = !GBPF_IS_TOKEN0;
        PoolKey memory key = _hookPoolKey();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(usdsIn); // exact input; queue total ≪ int256 max
        BalanceDelta delta = POOL_MANAGER.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}), ""
        );

        _settleLeg(key.currency0, delta.amount0());
        _settleLeg(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Delta from this contract's (the swapper's) perspective:
    ///        negative → we owe the PoolManager (sync + transfer + settle)
    ///        positive → the PoolManager owes us (take)
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

    /// @notice Convert `usdsAmount` of collected fee USDS to native ETH in the tank. Self-call only —
    ///         invoked by executeBatch through try/catch so a route failure can't block mints.
    function swapFeeToEth(uint256 usdsAmount) external {
        if (msg.sender != address(this)) revert NotSelf();

        // Hop 1: USDS → USDC via PSM3 (no fee). Preview gives an exact, in-block minOut.
        uint256 minUsdc = PSM3.previewSwapExactIn(USDS, USDC, usdsAmount);
        uint256 usdcOut = PSM3.swapExactIn(USDS, USDC, usdsAmount, minUsdc, address(this), 0);

        // Hop 2: USDC → WETH via the V3 pool (raw swap; we pay USDC in the callback).
        uint256 wethBefore = IERC20Like(WETH).balanceOf(address(this));
        bool zeroForOne = USDC_IS_TOKEN0; // selling USDC
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        USDC_WETH_POOL.swap(address(this), zeroForOne, int256(usdcOut), limit, "");
        uint256 wethOut = IERC20Like(WETH).balanceOf(address(this)) - wethBefore;

        // Hop 3: WETH → ETH.
        IWETH(WETH).withdraw(wethOut);
        emit FeeSwappedToEth(usdsAmount, wethOut);
    }

    /// @dev V3 swap callback: pay the USDC the pool is owed for the USDC → WETH swap.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(USDC_WETH_POOL)) revert NotV3Pool();
        // We only ever sell USDC, so exactly one positive delta — the USDC we owe.
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

    function setParams(uint256 feeUsds_, uint256 fixedFeeUsds_, uint256 bonusBps_, uint256 maxDepositors_)
        external
        onlyOwner
    {
        if (feeUsds_ > MAX_FEE_USDS || fixedFeeUsds_ > MAX_FIXED_FEE_USDS || bonusBps_ > MAX_BONUS_BPS) {
            revert ParamTooHigh();
        }
        if (maxDepositors_ == 0 || maxDepositors_ > MAX_MAX_DEPOSITORS) revert ParamTooHigh();
        feeUsds = feeUsds_;
        fixedFeeUsds = fixedFeeUsds_;
        bonusBps = bonusBps_;
        maxDepositors = maxDepositors_;
        emit ParamsUpdated(feeUsds_, fixedFeeUsds_, bonusBps_, maxDepositors_);
    }

    /// @notice Seed the ETH gas tank directly (also reachable via plain send / WETH withdraw).
    function fundTank() external payable {
        emit TankFunded(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH from the tank. Cannot touch queued USDS or escrowed GBPF.
    function withdrawEth(uint256 amount, address to) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit OwnerWithdrawal(address(0), amount, to);
    }

    /// @notice Rescue stray tokens. Guards the two balances users rely on: queued USDS and
    ///         escrowed GBPF can never be swept out from under depositors.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == USDS) {
            // Queued deposits are not strays.
            require(amount <= IERC20Like(USDS).balanceOf(address(this)) - totalQueued, "USDS reserved for queue");
        } else if (token == GBPF) {
            // Escrowed (claimable) GBPF is not a stray.
            require(amount <= IERC20Like(GBPF).balanceOf(address(this)) - totalClaimable, "GBPF reserved for escrow");
        }
        token.safeTransfer(to, amount);
        emit OwnerWithdrawal(token, amount, to);
    }

    // ============================================================================================
    // Internals / views
    // ============================================================================================

    function _removeDepositor(address d) internal {
        uint256 idx = depositorIndexPlus1[d] - 1; // reverts if 0 — but callers check pendingUsds first
        uint256 lastIdx = depositors.length - 1;
        if (idx != lastIdx) {
            address last = depositors[lastIdx];
            depositors[idx] = last;
            depositorIndexPlus1[last] = idx + 1;
        }
        depositors.pop();
        pendingUsds[d] = 0;
        depositorIndexPlus1[d] = 0;
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }

    function gasTank() external view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Accept ETH from WETH.withdraw and direct sends.
    receive() external payable {}
}
