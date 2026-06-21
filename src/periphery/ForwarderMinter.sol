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

/// @title ForwarderMinter
/// @notice Send-and-forget batched mint: a user sends USDS to their own deterministic deposit
///         address (a plain transfer — no approve, no contract call), and a permissionless
///         "runner" sweeps any set of users and mints them GBPF pro-rata through the V4 hook in
///         one transaction. The runner is reimbursed in ETH from a self-funding gas tank.
///
///         Attribution is trustless: a user's deposit address is `CREATE2(this, salt = user)`, so
///         funds there can only ever be credited to that user — the sweeper cannot reassign them.
///         See BATCHMINTER_DESIGN.md ("Forwarder model").
///
///         PERIPHERY, NOT CORE. Owner for tuning + rescue only; cannot touch user funds (which
///         live at user-bound forwarder addresses) or escrowed `claimable` GBPF.
contract ForwarderMinter is IUnlockCallback, IUniswapV3SwapCallback {
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

    bool public immutable GBPF_IS_TOKEN0;
    bool public immutable USDC_IS_TOKEN0;

    /// @dev keccak256 of the Forwarder creation code — fixes every user's deposit address.
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

    uint256 public feeUsds = 0.05e18; // per-depositor marginal fee
    uint256 public fixedFeeUsds = 0.1e18; // per-batch fixed fee, split /n
    uint256 public bonusBps = 2_000;
    uint256 public maxBatch = 150; // cap on users[] length per sweep

    // ============================================================================================
    // State
    // ============================================================================================

    /// @dev GBPF escrowed because a direct push to a user reverted. Pull with claim().
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    uint256 private _locked = 1;

    // ============================================================================================
    // Events / errors
    // ============================================================================================

    event Swept(address indexed user, uint256 usdsIn);
    event BatchExecuted(
        address indexed runner,
        uint256 userCount,
        uint256 usdsSwapped,
        uint256 gbpfOut,
        uint256 feeCollected,
        uint256 runnerPayoutWei
    );
    event Refunded(address indexed user, uint256 usdsReturned);
    event PushFailedEscrowed(address indexed user, uint256 gbpfAmount);
    event Claimed(address indexed user, uint256 gbpfAmount);
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
        FORWARDER_INIT_HASH = keccak256(type(Forwarder).creationCode);

        usds_.safeApprove(psm3_, type(uint256).max);
    }

    /// @notice The token a Forwarder sweeps to this factory (USDS). Read by Forwarder on deploy.
    function depositToken() external view returns (address) {
        return USDS;
    }

    // ============================================================================================
    // Deposit addresses (the user-facing primitive)
    // ============================================================================================

    /// @notice The deterministic USDS deposit address for `user`. The user just sends USDS here
    ///         (plain transfer); funds are provably theirs because the address encodes them.
    function depositAddressOf(address user) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(user), FORWARDER_INIT_HASH))))
        );
    }

    function _salt(address user) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    /// @dev Pull `user`'s forwarder balance into this contract. Deploys the forwarder the first
    ///      time (its constructor sweeps), flushes it thereafter. Returns the amount pulled.
    function _sweep(address user) internal returns (uint256 swept) {
        address f = depositAddressOf(user);
        if (IERC20Like(USDS).balanceOf(f) == 0) return 0;
        uint256 before = IERC20Like(USDS).balanceOf(address(this));
        if (f.code.length == 0) {
            Forwarder created = new Forwarder{salt: _salt(user)}();
            if (address(created) != f) revert ForwarderAddrMismatch();
        } else {
            Forwarder(f).flush();
        }
        swept = IERC20Like(USDS).balanceOf(address(this)) - before;
    }

    // ============================================================================================
    // Sweep + execute — the runner's entry point
    // ============================================================================================

    /// @notice Permissionless. Sweeps each user's USDS deposit, mints the lot through the hook,
    ///         sends each user their pro-rata GBPF, tops up the ETH tank from the fees, and pays
    ///         the caller (the runner) gas + bonus. Users with an empty deposit are skipped.
    /// @param  users      Candidate depositor wallets (discovered off-chain). Duplicates/empties
    ///                    are harmless no-ops.
    /// @param  minGbpfOut Abort if the hook would return less GBPF than this.
    function sweepAndExecute(address[] calldata users, uint256 minGbpfOut) external nonReentrant {
        uint256 gasStart = gasleft();

        uint256 len = users.length;
        if (len > maxBatch) revert BatchTooLarge();

        // 1. Sweep every user's forwarder; collect amounts in memory. No persistent queue — the
        //    deposits live at the forwarder addresses until this atomic sweep.
        uint256[] memory amounts = new uint256[](len);
        uint256 count;
        uint256 total;
        for (uint256 i = 0; i < len; ++i) {
            uint256 swept = _sweep(users[i]);
            amounts[i] = swept;
            if (swept > 0) {
                count += 1;
                total += swept;
                emit Swept(users[i], swept);
            }
        }
        if (total == 0) revert NothingToDo();

        // 2. Per-user fee = marginal + equal share of the fixed (capped at the user's balance).
        uint256 perHead = feeUsds + fixedFeeUsds / count;
        uint256 totalFee;
        for (uint256 i = 0; i < len; ++i) {
            uint256 a = amounts[i];
            if (a > 0) totalFee += a < perHead ? a : perHead;
        }
        uint256 swapUsds = total - totalFee;
        if (swapUsds == 0) revert NothingToDo();

        // 3. Mint through the hook.
        uint256 gbpfBefore = IERC20Like(GBPF).balanceOf(address(this));
        POOL_MANAGER.unlock(abi.encode(swapUsds));
        uint256 gbpfOut = IERC20Like(GBPF).balanceOf(address(this)) - gbpfBefore;
        if (gbpfOut < minGbpfOut || gbpfOut == 0) revert SlippageOrPause();

        // 4. Distribute pro-rata to each user's net (post-fee) USDS.
        for (uint256 i = 0; i < len; ++i) {
            uint256 a = amounts[i];
            if (a == 0) continue;
            uint256 net = a - (a < perHead ? a : perHead);
            if (net > 0) {
                uint256 share = FixedPointMathLib.mulDiv(gbpfOut, net, swapUsds);
                if (share > 0) _pushOrEscrow(users[i], share);
            }
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

        emit BatchExecuted(msg.sender, count, swapUsds, gbpfOut, totalFee, payout);
    }

    /// @notice Permissionless escape hatch: sweep `user`'s deposit and return it straight to them
    ///         as USDS (no swap, no fee). Safe to let anyone call — it can only return funds to
    ///         the address that owns them.
    function refund(address user) external nonReentrant {
        uint256 swept = _sweep(user);
        if (swept == 0) revert NothingToDo();
        USDS.safeTransfer(user, swept);
        emit Refunded(user, swept);
    }

    /// @notice Pull GBPF escrowed for you because a direct push failed.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToDo();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        GBPF.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

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

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 usdsIn = abi.decode(data, (uint256));

        bool zeroForOne = !GBPF_IS_TOKEN0; // mint runs zeroForOne when USDS is currency0
        PoolKey memory key = _hookPoolKey();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountSpecified = -int256(usdsIn);
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
    // Fee → ETH (USDS → USDC → WETH → ETH)
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

    /// @notice Rescue strays. Escrowed (claimable) GBPF can never be swept out. No USDS reserve
    ///         is needed: user USDS lives at forwarder addresses, not here, between batches.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == GBPF) {
            require(amount <= IERC20Like(GBPF).balanceOf(address(this)) - totalClaimable, "GBPF reserved for escrow");
        }
        token.safeTransfer(to, amount);
        emit OwnerWithdrawal(token, amount, to);
    }

    function gasTank() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
